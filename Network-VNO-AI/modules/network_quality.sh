#!/bin/bash
# Network-VNO-AI 高级诊断：网络质量测量（network_quality.sh）
# 任务书第 8.1 章（RTT 多目标测量：IPv4/IPv6、最小/平均/最大/p50/p95/抖动/丢包）
# 规则：纯 Bash；依赖探测；默认只读；不主动产生下载流量（测速由 bandwidth_test.sh 负责，默认允许但会先提示流量）；
#       不把 ICMP RTT 直接当作 TCP 实际连接 RTT（明确标注）；统一 JSON 到 data/network_quality.json。
# 路径走 common.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="网络质量测量"
JSON_FILE="${DATA_DIR}/network_quality.json"

# 测量单个目标的 RTT。用法：measure_rtt <目标> <count> <ipv6?>
# 输出：一行 "min avg max mdev loss p50 p95"，采集失败输出空
measure_rtt() {
    local target="$1" count="${2:-5}" ipv6="${3:-0}"
    local ping_opt=""
    [[ "$ipv6" == "1" ]] && ping_opt="-6"
    [[ -z "$(have_cmd ping && echo x)" ]] && { echo ""; return; }
    local raw
    raw=$(ping $ping_opt -c "$count" -W 2 "$target" 2>/dev/null) || { echo ""; return; }
    local times
    times=$(echo "$raw" | grep -oE 'time=[0-9.]+ ms' | sed 's/time=//;s/ ms//')
    [[ -z "$times" ]] && { echo ""; return; }
    local loss
    loss=$(echo "$raw" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+' | head -1)
    [[ -z "$loss" ]] && loss=0
    local min avg max mdev
    # 以「数字/数字/数字/数字 ms」精确提取 min/avg/max/mdev（避免字段错位与单位污染）
    read -r min avg max mdev < <(echo "$raw" | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+ ms' | head -1 | sed -E 's#([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms#\1 \2 \3 \4#')
    # p50/p95（对每跳时延排序取分位）
    local p50 p95
    p50=$(echo "$times" | sort -n | awk '{a[NR]=$1} END{n=NR; i=int(n*0.5)+1; if(i<1)i=1; if(i>n)i=n; print a[i]}')
    p95=$(echo "$times" | sort -n | awk '{a[NR]=$1} END{n=NR; i=int(n*0.95)+1; if(i<1)i=1; if(i>n)i=n; print a[i]}')
    echo "${min:-0} ${avg:-0} ${max:-0} ${mdev:-0} ${loss:-0} ${p50:-0} ${p95:-0}"
}

# 取默认网关
default_gw() {
    [[ -n "$(have_cmd ip && echo x)" ]] && ip route show default 2>/dev/null | awk '{print $3; exit}'
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在测量网络链路质量（RTT / 抖动 / 丢包），不主动产生下载流量..."

    local targets=()
    local gw; gw="$(default_gw)"
    [[ -n "$gw" && "$gw" != "via" ]] && targets+=("网关:${gw}")
    targets+=("公网:1.1.1.1" "公网:8.8.8.8")
    [[ -n "$(have_cmd ip && ip -6 addr show 2>/dev/null | grep -q inet6 && echo x)" ]] && targets+=("公网IPv6:2606:4700:4700::1111")

    local best_target="" best_avg="未知"
    local tgt_entries=""
    for t in "${targets[@]}"; do
        local label="${t%%:*}"; host="${t#*:}"
        local res; res=$(measure_rtt "$host" 5 0)
        if [[ -z "$res" ]]; then
            vno_log WARN "目标 ${host}（${label}）不可达或无法测量，已跳过"
            tgt_entries="${tgt_entries}    \"${label}|${host}\": { \"reachable\": false },
"
            continue
        fi
        local rmin ravg rmax rmdev rloss rp50 rp95
        read -r rmin ravg rmax rmdev rloss rp50 rp95 <<< "$res"
        vno_log INFO "${label} ${host}：RTT 最小/平均/最大=${rmin}/${ravg}/${rmax}ms，抖动=${rmdev}ms，p50=${rp50}ms，p95=${rp95}ms，丢包=${rloss}%"
        tgt_entries="${tgt_entries}    \"${label}|${host}\": {
      \"reachable\": true,
      \"min_ms\": ${rmin:-0},
      \"avg_ms\": ${ravg:-0},
      \"max_ms\": ${rmax:-0},
      \"mdev_jitter_ms\": ${rmdev:-0},
      \"p50_ms\": ${rp50:-0},
      \"p95_ms\": ${rp95:-0},
      \"packet_loss_pct\": ${rloss:-0}
    },
"
        if [[ "$best_avg" == "未知" ]] || awk "BEGIN{exit !($ravg < $best_avg)}" 2>/dev/null; then
            best_target="$host"; best_avg="$ravg"
        fi
    done
    tgt_entries="$(printf '%s' "$tgt_entries" | sed '$ s/,$//')"

    if [[ "$best_avg" == "未知" ]]; then
        vno_log WARN "所有测试目标均不可达（可能无网络或 ping 不可用），RTT 标注为未知，不虚构数值"
        best_target="未知"
    fi
    local bmin bavg bmax bmdev bloss bp50 bp95
    if [[ "$best_target" != "未知" ]]; then
        # 用最佳目标再测一次拿代表值
        local r; r="$(measure_rtt "$best_target" 10 0)"
        if [[ -n "$r" ]]; then read -r bmin bavg bmax bmdev bloss bp50 bp95 <<< "$r"; fi
    fi
    bmin="${bmin:-未知}"; bavg="${bavg:-未知}"; bmax="${bmax:-未知}"; bmdev="${bmdev:-未知}"; bloss="${bloss:-未知}"; bp50="${bp50:-未知}"; bp95="${bp95:-未知}"

    echo "网络质量测量完成（代表性 RTT 来自：${best_target}）"
    vno_log INFO "代表 RTT：平均=${bavg}ms，p95=${bp95}ms，抖动=${bmdev}ms，丢包=${bloss}%"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"network_quality\","
      echo "  \"stage\": 6,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"note\": \"ICMP RTT 不等同 TCP 实际连接 RTT；p50/p95 基于多轮采样\","
      echo "  \"targets\": {"
      echo "$tgt_entries"
      echo "  },"
      echo "  \"summary\": {"
      echo "    \"best_target\": \"$(sanitize_json "$best_target")\","
      echo "    \"min_ms\": \"${bmin}\","
      echo "    \"avg_ms\": \"${bavg}\","
      echo "    \"max_ms\": \"${bmax}\","
      echo "    \"mdev_jitter_ms\": \"${bmdev}\","
      echo "    \"p50_ms\": \"${bp50}\","
      echo "    \"p95_ms\": \"${bp95}\","
      echo "    \"packet_loss_pct\": \"${bloss}\""
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"网络质量测量完成，未修改系统配置；RTT 为 ICMP 测量，非 TCP 实际连接 RTT\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存网络质量数据到 ${JSON_FILE}"
    echo "阶段 6 模块 network_quality 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
