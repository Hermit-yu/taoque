#!/usr/bin/env bash
# ============================================================================
# lib/netdetect.sh — 网络环境检测（任务书 §5）
# 输出全局：
#   NET[rtt_ms] / NET[rtt_min] / NET[rtt_max] / NET[rtt_jitter] / NET[rtt_target]
#   NET[rtt_trust]  可信度标记(high/medium/low/unmeasured)
#   NET[bandwidth_mbps] / NET[bandwidth_source]
# 纪律：
#   - Ping 延迟 ≠ TCP RTT，必须标注可信度（任务书 §5.1）
#   - 多目标检测避免单点误判
#   - 网卡标称速率 ≠ 公网带宽（§5.2）
#   - 未经授权不下载大文件/不跑高流量测速；iperf3 可选且需显式开关
# ============================================================================

declare -gA NET=()
NET[rtt_ms]="UNMEASURED"; NET[rtt_min]=""; NET[rtt_max]=""
NET[rtt_jitter]=""; NET[rtt_target]=""; NET[rtt_trust]="unmeasured"
NET[bandwidth_mbps]="${TWO_BANDWIDTH_Mbps:-}"; NET[bandwidth_source]=""
NET[iperf3_result]="UNTESTED"
NET[rtt_ping_count]="${TWO_PING_COUNT:-8}"

two_net_rtt() {
  # 多目标 RTT：默认网关 + 1.1.1.1 + 8.8.8.8（可用时可注入 TWO_PING_TARGETS）
  local -a targets=()
  local gw
  gw="$({ [[ -r "$TWO_BASE_PROC/route.default" ]] && awk '/^default/{print $1; exit}' "$TWO_BASE_PROC/route.default"; } 2>/dev/null || true)"
  if [[ -z "$gw" ]] && two_have_cmd ip >/dev/null; then
    gw="$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+2); exit}}' || true)"
  fi
  [[ -n "$gw" ]] && targets+=("$gw")
  local custom="${TWO_PING_TARGETS:-1.1.1.1 8.8.8.8}"
  local t
  for t in $custom; do targets+=("$t"); done

  if ! two_have_cmd ping >/dev/null; then
    # ping 不可用：尝试用已有 TCP 连接抓 RTT（可信度 low），否则标记 unmeasured
    two_log_if WARN "ping 不可用，尝试从已有连接读取 RTT（可信度 low）"
    two_net_rtt_from_sockets
    return 0
  fi

  local n="${NET[rtt_ping_count]:-8}"
  local all_min="" all_max="" all_cnt=0
  for t in "${targets[@]}"; do
    [[ -z "$t" ]] && continue
    local stats
    stats="$(ping -c "$n" -W 2 "$t" 2>/dev/null | awk -F'/' '
      /rtt|round-trip/{print}' || true)"
    if [[ -n "$stats" ]]; then
      # 形如: rtt min/avg/max/mdev = 0.986/1.016/1.046/0.030 ms
      # 提取等号后的四个数字，分割为 min avg max mdev
      local mn av mx
      mn="$(printf '%s\n' "$stats" | awk '{for(i=1;i<=NF;i++) if($i=="=") {val=$(i+1); split(val,a,"/"); print a[1]; exit}}')"
      av="$(printf '%s\n' "$stats" | awk '{for(i=1;i<=NF;i++) if($i=="=") {val=$(i+1); split(val,a,"/"); print a[2]; exit}}')"
      mx="$(printf '%s\n' "$stats" | awk '{for(i=1;i<=NF;i++) if($i=="=") {val=$(i+1); split(val,a,"/"); print a[3]; exit}}')"
      [[ -n "$mn" && -n "$av" ]] || continue
      if [[ -z "$all_min" || "$mn" < "$all_min" ]]; then all_min="$mn"; fi
      if [[ -z "$all_max" || "$mx" > "$all_max" ]]; then all_max="$mx"; fi
      all_cnt=$((all_cnt+1))
      # 记录成功目标
      case " ${NET[rtt_target]:-} " in *" $t "*) :;; *) NET[rtt_target]="${NET[rtt_target]:-} ${t}";; esac
    else
      two_log_if DEBUG "目标 $t 不可达，已跳过"
    fi
  done

  if (( all_cnt == 0 )); then
    two_net_rtt_from_sockets
    [[ "${NET[rtt_ms]:-}" == "UNMEASURED" ]] && two_log_if WARN "所有 ping 目标均不可达，RTT 标记为 UNMEASURED"
    return 0
  fi

  # 汇总：多目标 avg 用 min..max 中位思想简化为 (min+max)/2 作保守均值
  NET[rtt_min]="$all_min"
  NET[rtt_max]="$all_max"
  NET[rtt_ms]="$(awk -v a="$all_min" -v b="$all_max" 'BEGIN{printf "%.1f", (a+b)/2}')"
  NET[rtt_jitter]="$(awk -v a="$all_min" -v b="$all_max" 'BEGIN{printf "%.1f", b-a}')"
  if (( all_cnt >= 2 )); then
    NET[rtt_trust]="medium"   # 多目标一致
  else
    NET[rtt_trust]="low"      # 单目标
  fi
  NET[rtt_note]="Ping RTT，非 TCP 实际连接 RTT；多目标取保守区间"
  two_log_if INFO "RTT 检测完成: ${NET[rtt_ms]}ms (min ${NET[rtt_min]} / max ${NET[rtt_max]} / 抖动 ${NET[rtt_jitter]}), 可信度=${NET[rtt_trust]}"
  return 0
}

# ping 全失败时的兜底：读 /proc/net/snmp 或 ss 的已有连接 RTT（尽力）
two_net_rtt_from_sockets() {
  local rtt
  if two_have_cmd ss >/dev/null; then
    rtt="$(ss -ti 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i~/rtt:/) {gsub(/rtt:/,"",$i); split($i,a,"/"); if(a[1]!="") {print a[1]; exit}}}')"
    if [[ -n "$rtt" ]]; then
      NET[rtt_ms]="$rtt"; NET[rtt_min]="$rtt"; NET[rtt_max]="$rtt"; NET[rtt_jitter]="$rtt"
      NET[rtt_target]="existing-tcp-conn"; NET[rtt_trust]="low"
      NET[rtt_note]="来自 ss 已有 TCP 连接 RTT（非受控测量），可信度 low"
      return 0
    fi
  fi
  # 都没有：给保守默认（100ms），明确标注
  NET[rtt_ms]="100"; NET[rtt_min]=""; NET[rtt_max]=""
  NET[rtt_trust]="unmeasured"; NET[rtt_note]="无法测量 RTT，采用保守默认 100ms（远程链路常见值），结果可信度低"
  return 0
}

two_net_bandwidth() {
  # 带宽来源优先级（任务书 §5.2 + 检测参考数据）：
  #  1) 用户显式指定 TWO_BANDWIDTH_Mbps / --bandwidth <Mbps>
  #  2) 既有测速结果 TWO_IPERF3_RESULT_Mbps
  #  3) 主动网速测试(curl 下载限量文件, 默认开启, --no-speedtest 可关)
  #  4) 保守默认 100Mbps + 明确说明
  if [[ -n "${NET[bandwidth_mbps]:-}" ]]; then
    NET[bandwidth_source]="用户指定"
    return 0
  fi
  if [[ -n "${TWO_IPERF3_RESULT_Mbps:-}" ]]; then
    NET[bandwidth_mbps]="$TWO_IPERF3_RESULT_Mbps"; NET[bandwidth_source]="既有测速结果"
    return 0
  fi
  # 主动网速测试（小流量、限时、失败不阻断）
  two_net_speedtest
  if [[ "${NET[speedtest_status]:-}" == "OK" && -n "${NET[speedtest_mbps]:-}" ]]; then
    NET[bandwidth_mbps]="${NET[speedtest_mbps]}"
    NET[bandwidth_source]="主动网速测试(${NET[speedtest_detail]:-})"
    return 0
  fi
  if [[ "${TWO_ENABLE_IPERF3:-0}" == "1" ]] && two_have_cmd iperf3 >/dev/null; then
    two_net_iperf3_test
    if [[ -n "${NET[bandwidth_mbps]:-}" ]]; then
      NET[bandwidth_source]="iperf3 实测(${NET[rtt_target]:-target})"
      return 0
    fi
  elif [[ "${TWO_ENABLE_IPERF3:-0}" == "1" ]]; then
    two_note_missing iperf3 "已请求 iperf3 测速但命令不存在，退回保守带宽"
  fi
  # 保守默认
  NET[bandwidth_mbps]="${TWO_DEFAULT_BANDWIDTH_Mbps:-100}"
  NET[bandwidth_source]="保守默认值(未提供/未测得公网带宽，主动测速未成功)。请在报告中确认实际带宽，或用 --bandwidth <Mbps> 指定"
  two_log_if WARN "公网带宽未测得，使用保守默认 ${NET[bandwidth_mbps]}Mbps —— 可用 --bandwidth <Mbps> 或 --speedtest-url <URL> 改善"
  return 0
}

# ============================================================================
# 主动网速测试（为参数计算提供参考带宽）
# 纪律（任务书 §5.2 + 用户需求）：
#   - 默认在检测时开启，下载量封顶 TWO_SPEEDTEST_MB(默认 20MB)、限时 30s，属小流量
#   - 不落盘(-o /dev/null)、不并发刷流；--no-speedtest 或 TWO_DISABLE_SPEEDTEST=1 关闭
#   - 数据不足/超时/无 curl 时【不阻断检测】，退回下一带宽来源并明确标注
#   - 结果标来源，报告可追溯
# ============================================================================

two_net_speedtest() {
  NET[speedtest_status]="NOT_RUN"
  NET[speedtest_detail]=""
  NET[speedtest_mbps]=""
  if [[ "${TWO_DISABLE_SPEEDTEST:-0}" == "1" ]]; then
    NET[speedtest_status]="DISABLED(--no-speedtest)"
    return 0
  fi
  local mb="${TWO_SPEEDTEST_MB:-20}"
  local timeout_s="${TWO_SPEEDTEST_TIMEOUT:-30}"
  local url="${TWO_SPEEDTEST_URL:-https://speed.cloudflare.com/__down?bytes=$(( mb * 1000000 ))}"
  if two_have_cmd curl >/dev/null; then
    two_net_speedtest_with_curl "$url" "$timeout_s" "$mb"
  elif two_have_cmd wget >/dev/null; then
    two_net_speedtest_with_wget "$url" "$timeout_s" "$mb"
  else
    two_note_missing curl "主动网速测试跳过(curl/wget 均不可用)"
    NET[speedtest_status]="NO_TOOL(无 curl/wget)"
  fi
  return 0
}

two_net_speedtest_with_curl() {
  local url="$1" timeout_s="$2" mb="$3"
  two_log_if INFO "主动网速测试: 下载 ${mb}MB 参考文件(限时 ${timeout_s}s, 目标: $url)…"
  local stat rc
  stat="$(curl -L -o /dev/null -s -w '%{size_download} %{time_total}' --max-time "$timeout_s" "$url" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    two_log_if WARN "网速测试下载失败(curl exit=$rc, 目标不可达/被拒/超时)，退回下一带宽来源"
    NET[speedtest_status]="FAILED(curl exit=$rc)"
    return 0
  fi
  local bytes secs
  bytes="${stat%% *}"; secs="${stat#* }"
  # 有效性门槛：≥512KB 且 ≥0.5s（排除 CDN 秒回缓存值失真）
  if [[ "${bytes:-0}" -ge 524288 ]] && awk -v s="${secs:-0}" 'BEGIN{exit !(s>=0.5)}'; then
    local m
    m="$(awk -v b="$bytes" -v s="$secs" 'BEGIN{printf "%.1f", b*8/1000000/s}')"
    NET[speedtest_mbps]="$m"
    NET[speedtest_detail]="curl 下载参考文件: ${bytes}B 用时 ${secs}s"
    NET[speedtest_status]="OK"
    two_log_if INFO "网速测试完成: 下载 ${m}Mbps (${NET[speedtest_detail]}, 目标 $url)"
  else
    two_log_if WARN "网速测试数据不足(下载 ${bytes:-0}B / ${secs:-0}s, 或目标异常快/慢)，结果不可信，已丢弃"
    NET[speedtest_status]="INSUFFICIENT(${bytes:-0}B/${secs:-0}s)"
  fi
  return 0
}

two_net_speedtest_with_wget() {
  local url="$1" timeout_s="$2" mb="$3"
  two_log_if INFO "主动网速测试(wget 兜底): 下载 ${mb}MB 参考文件(限时 ${timeout_s}s)…"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/two-speedtest.XXXXXX" 2>/dev/null || echo "/dev/null")"
  local stat rc
  stat="$(wget -O "$tmp" -q --timeout="$timeout_s" "$url" 2>/dev/null && ls -l "$tmp" 2>/dev/null | awk '{print $5}' || echo 0)"
  rc=$?
  rm -f "$tmp" 2>/dev/null || true
  if (( stat >= 524288 )) && [[ "$rc" == "0" ]]; then
    # wget 无法取精确耗时，用 文件大小/10s 粗估不可靠，降级：只记成功不记速率
    two_log_if WARN "wget 测速无法取精确耗时，只记录'下载成功'，不产生速率值（建议装 curl 获得精确测速）"
    NET[speedtest_status]="OK_NO_RATE"
  else
    NET[speedtest_status]="FAILED(wget rc=$rc)"
    two_log_if WARN "网速测试下载失败(wget exit=$rc)，退回下一带宽来源"
  fi
  return 0
}

two_net_iperf3_test() {
  # 授权后的可选测速：短时长，避免高流量（任务书 §5.2 限制）
  local target="${TWO_IPERF3_TARGET:-$({ [[ -r "$TWO_BASE_PROC/route.default" ]] && awk '/^default/{print $3; exit}' "$TWO_BASE_PROC/route.default"; })}"
  two_log_if INFO "开始 iperf3 测速目标=$target (10s, -P2)…"
  if iperf3 -c "$target" -t 10 -P 2 -J >/dev/null 2>&1; then
    # 简易：取 receiver 吞吐
    local mbps
    mbps="$(iperf3 -c "$target" -t 5 -P 1 2>/dev/null | awk -F'/' '/receiver/{gsub(/,/,"",$5); print $5/1000; exit}')"
    [[ -n "$mbps" ]] && NET[bandwidth_mbps]="$mbps"
  else
    two_log_if WARN "iperf3 测速失败(网络不允许/无对端)，退回保守带宽"
  fi
  return 0
}

two_net_detect_all() {
  two_net_rtt
  two_net_bandwidth
  # 结构化提示：直接输出实测速度与延迟（非从报告读取，直接取检测变量）
  printf '网络检测: 带宽=%sMbps(来源:%s) 延迟=%sms(可信度:%s) 测速状态=%s 详情=%s\n' \
    "${NET[bandwidth_mbps]:-未测}" \
    "${NET[bandwidth_source]:-未知}" \
    "${NET[rtt_ms]:-未测}" \
    "${NET[rtt_trust]:-低}" \
    "${NET[speedtest_status]:-无}" \
    "${NET[speedtest_detail]:-无}"
  return 0
}
