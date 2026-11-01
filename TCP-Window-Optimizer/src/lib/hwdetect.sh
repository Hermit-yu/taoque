#!/usr/bin/env bash
# ============================================================================
# lib/hwdetect.sh — VPS 硬件自动检测（任务书 §2）
# 输出全局变量：
#   TWO_CPU_* / TWO_MEM_* / TWO_NET_*
# 数据源可经 TWO_BASE_PROC / TWO_BASE_SYS 重定向（单元测试 fixtures）
# 任何单项检测失败不致命：置 UNKNOWN 并记录原因
# ============================================================================

declare -gA HW=()     # 扁平键值，报告直接遍历
declare -gA HW_RISK=() # 需要人工关注的问题

# ---- 2.1 CPU ----
two_hw_cpu() {
  local cpuinfo="$TWO_BASE_PROC/cpuinfo"
  # 型号
  if [[ -r "$cpuinfo" ]]; then
    HW[cpu_model]="$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' "$cpuinfo" 2>/dev/null || true)"
  fi
  HW[cpu_model]="${HW[cpu_model]:-UNKNOWN}"

  # 物理核 / 逻辑核
  if [[ -r "$cpuinfo" ]]; then
    HW[cpu_cores]="$(grep -c '^processor' "$cpuinfo" 2>/dev/null || echo UNKNOWN)"
    # 物理核数：唯一 (physical id, core id) 组合（/proc/cpuinfo 用制表符分隔）
    if [[ -r "$cpuinfo" ]]; then
      local uniq
      uniq="$(awk 'BEGIN{FS=":"}
        /^physical id[ \t]*:/ {gsub(/[ \t]/,"",$2); p=$2}
        /^core id[ \t]*:/     {gsub(/[ \t]/,"",$2); c=$2; k=p"/"c; if(!(k in seen)){seen[k]=1; n++}}
        END{print n+0}' "$cpuinfo" 2>/dev/null || echo 0)"
      if [[ "$uniq" == "0" || -z "$uniq" ]]; then
        HW[cpu_physical]="UNKNOWN(该 cpuinfo 无 physical/core id, 常见于极简 VPS)"
      else
        HW[cpu_physical]="$uniq"
      fi
    fi
  else
    HW[cpu_cores]="UNKNOWN"; HW[cpu_physical]="UNKNOWN"
  fi
  # nproc 兜底（无 cpuinfo 时）
  if [[ "${HW[cpu_cores]}" == "UNKNOWN" ]] && two_have_cmd nproc >/dev/null; then
    HW[cpu_cores]="$(nproc 2>/dev/null || echo UNKNOWN)"
    HW[cpu_logical]="$((HW[cpu_cores]))"
  else
    HW[cpu_logical]="${HW[cpu_cores]}"
  fi

  # 架构
  if HW[arch]="$(uname -m 2>/dev/null || true)"; [[ -z "${HW[arch]:-}" ]]; then HW[arch]="UNKNOWN"; fi

  # 虚拟化类型
  local virt="物理机/未知"
  if two_have_cmd systemd-detect-virt >/dev/null; then
    virt="$(systemd-detect-virt 2>/dev/null || echo none)"
    [[ "$virt" == "none" ]] && virt="未检测到虚拟化(可能是物理机)"
  elif [[ -r "$TWO_BASE_PROC/cpuinfo" ]]; then
    local hyp
    hyp="$(grep -m1 -E '^hypervisor' "$TWO_BASE_PROC/cpuinfo" 2>/dev/null || true)"
    [[ -n "$hyp" ]] && virt="存在 hypervisor CPU flag(KVM/嵌套虚拟化)"
    local vendor
    vendor="$(awk -F: '/vendor_id/{gsub(/^ +/,"",$2); print $2; exit}' "$TWO_BASE_PROC/cpuinfo" 2>/dev/null || true)"
    case "$vendor" in
      GenuineIntel) virt="$virt (Intel)";;
      AuthenticAMD) virt="$virt (AMD)";;
    esac
  fi
  HW[cpu_virt]="$virt"
  HW[cpu_is_vps]="$([[ "$virt" != *"未检测到"* && -n "${HW[cpu_virt]:-}" && "${HW[cpu_virt]}" != "物理机/未知" ]] && echo yes || echo no)"

  # 主频
  if two_have_cmd lscpu >/dev/null; then
    local f
    f="$(lscpu 2>/dev/null | awk -F: '/CPU MHz/{gsub(/ /,"",$2); print $2; exit}')"
    HW[cpu_mhz]="${f:-UNKNOWN}"
  elif [[ -r "$TWO_BASE_PROC/cpuinfo" ]]; then
    HW[cpu_mhz]="$(awk -F: '/cpu MHz/{gsub(/^ +/,"",$2); print $2; exit}' "$TWO_BASE_PROC/cpuinfo" 2>/dev/null || echo UNKNOWN)"
  else
    HW[cpu_mhz]="UNKNOWN"
  fi

  # 负载
  if [[ -r "$TWO_BASE_PROC/loadavg" ]]; then
    HW[load_avg]="$(awk '{print $1" / "$2" / "$3}' "$TWO_BASE_PROC/loadavg" 2>/dev/null || echo UNKNOWN)"
  elif two_have_cmd uptime >/dev/null; then
    HW[load_avg]="$(uptime 2>/dev/null | grep -oE 'load average[s]?[^,]*' | head -1 || echo UNKNOWN)"
  else
    HW[load_avg]="UNKNOWN"
  fi

  # CPU 使用率（top 单次采样，尽力而为）
  if two_have_cmd top >/dev/null && [[ -t 1 || "${TWO_NONINTERACTIVE:-}" == "1" ]]; then
    HW[cpu_usage]="$(top -bn1 2>/dev/null | grep -iE 'cpu(s)? ' | head -1 || echo UNKNOWN)"
  else
    HW[cpu_usage]="UNKNOWN(未采样, 非交互环境)"
  fi
}

# ---- 2.2 内存 ----
two_hw_mem() {
  local meminfo="$TWO_BASE_PROC/meminfo"
  local total_kb avail_kb free_kb swap_kb swap_free_kb
  if [[ -r "$meminfo" ]]; then
    total_kb="$(awk '/^MemTotal:/{print $2}' "$meminfo" 2>/dev/null || true)"
    avail_kb="$(awk '/^MemAvailable:/{print $2}' "$meminfo" 2>/dev/null || true)"
    free_kb="$(awk '/^MemFree:/{print $2}' "$meminfo" 2>/dev/null || true)"
    swap_kb="$(awk '/^SwapTotal:/{print $2}' "$meminfo" 2>/dev/null || true)"
    swap_free_kb="$(awk '/^SwapFree:/{print $2}' "$meminfo" 2>/dev/null || true)"
  fi
  # free 命令兜底
  if [[ -z "${total_kb:-}" ]] && two_have_cmd free >/dev/null; then
    local line
    line="$(free -k 2>/dev/null | awk '/^Mem:/{print $2}' || true)"
    total_kb="$line"
  fi
  [[ -z "${total_kb:-}" ]] && { HW[mem_total_mb]="UNKNOWN"; HW[mem_total_mb_int]="0"; HW_RISK[mem]="无法获取内存总量"; return 1; }

  HW[mem_total_mb]="$((total_kb/1024))"
  HW[mem_total_mb_int]="${HW[mem_total_mb]}"

  # 小内存识别（任务书强制）
  local tier
  case $((total_kb/1024)) in
    512) tier="512MB 微型 VPS";;
    768) tier="768MB 微型 VPS";;
    1024) tier="1GB 小内存 VPS";;
    2048) tier="2GB 小内存 VPS";;
    4096) tier="4GB 常规 VPS";;
    8192) tier="8GB 中大型 VPS";;
    16384) tier="16GB 大内存 VPS";;
    32768) tier="32GB 大内存 VPS";;
    65536) tier="64GB+ 服务器级";;
    *)
      local mb
      mb=$(( total_kb/1024 ))
      if (( mb < 512 )); then
        tier="<512MB 极小 VPS"
      else
        tier="${mb}MB VPS(自定义档位)"
      fi;;
  esac
  HW[mem_tier]="$tier"

  # 可用内存
  local used_kb buf_cache=0
  if [[ -n "${avail_kb:-}" ]]; then
    HW[mem_avail_mb]="$((avail_kb/1024))"
    used_kb=$(( total_kb - avail_kb ))
  else
    # 老内核无 MemAvailable，用 Free+Buffers+Cached 近似（并标注可信度）
    buf_cache="$(awk '/^Buffers:/{b=$2}/^Cached:/{c=$2}END{print b+c}' "$meminfo" 2>/dev/null || echo 0)"
    local approx_avail=$(( ${free_kb:-0} + buf_cache ))
    HW[mem_avail_mb]="$(( approx_avail / 1024 ))"
    HW[mem_avail_note]="旧内核近似值(Free+Buffers+Cached)"
    used_kb=$(( total_kb - approx_avail ))
  fi
  (( used_kb < 0 )) && used_kb=0
  HW[mem_used_mb]="$(( used_kb / 1024 ))"
  HW[mem_used_pct]="$(( 100 * used_kb / total_kb ))"

  # Swap
  [[ -n "${swap_kb:-}" ]] || swap_kb=0
  HW[swap_total_mb]="$(( swap_kb / 1024 ))"
  local swap_used=$(( swap_kb - ${swap_free_kb:-0} ))
  (( swap_used < 0 )) && swap_used=0
  HW[swap_used_mb]="$(( swap_used / 1024 ))"

  # 小内存强制约束标记（任务书 §特别要求）
  if (( total_kb/1024 <= 1024 )); then
    HW[mem_small]="yes"
    HW_RISK[mem_small]="内存 ≤1GB：禁止盲目设置过大 TCP 缓冲区，避免内存压力/OOM"
  else
    HW[mem_small]="no"
  fi
  return 0
}

# ---- 2.3 网卡 ----
two_hw_net() {
  local netdir="$TWO_BASE_SYS/class/net"
  # 默认路由网卡：fixture 用 route.default，真实用 ip route
  local default_iface=""
  if [[ -r "$TWO_BASE_PROC/route.default" ]]; then
    default_iface="$(awk '/^default/{print $3}' "$TWO_BASE_PROC/route.default" 2>/dev/null | head -1)"
  elif two_have_cmd ip >/dev/null; then
    default_iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
    [[ -z "${default_iface:-}" ]] && default_iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true)"
  fi

  if [[ -z "${default_iface:-}" ]]; then
    # 兜底：第一个 UP 且非 lo 的接口
    for d in "$netdir"/*; do
      local n; n="$(basename "$d")"
      [[ "$n" == "lo" ]] && continue
      if [[ -r "$d/operstate" ]]; then
        [[ "$(cat "$d/operstate" 2>/dev/null || true)" == "up" ]] && { default_iface="$n"; break; }
      else
        default_iface="$n"; break
      fi
    done
  fi
  [[ -z "${default_iface:-}" ]] && { HW[net_iface]="UNKNOWN"; HW_RISK[net]="未找到默认路由网卡"; return 1; }

  HW[net_iface]="$default_iface"
  local ifdir="$netdir/$default_iface"

  # MTU / 状态 / MAC(仅本地) / 类型
  HW[net_mtu]="$({ [[ -r "$ifdir/mtu" ]] && cat "$ifdir/mtu"; } 2>/dev/null || echo UNKNOWN)"
  HW[net_state]="$({ [[ -r "$ifdir/operstate" ]] && cat "$ifdir/operstate"; } 2>/dev/null || echo UNKNOWN)"
  HW[net_type]="$({ [[ -r "$ifdir/type" ]] && cat "$ifdir/type"; } 2>/dev/null || echo unknown)"
  if [[ -r "$ifdir/address" ]]; then
    local mac; mac="$(cat "$ifdir/address" 2>/dev/null || true)"
    # MAC 只保留在本进程变量用于本地检测展示，不写入日志文件（任务书 §2.3 不上传）
    HW[net_mac_local_only]="$(echo "$mac" | sed -E 's/^.{2}/**/; s/..$/**/' | tr 'A-Z' 'a-z' 2>/dev/null || echo 已脱敏)"
  else
    HW[net_mac_local_only]="UNKNOWN"
  fi

  # 速率（虚拟网卡常无 speed，标注）
  local speed=""
  if [[ -r "$ifdir/speed" ]]; then
    speed="$(cat "$ifdir/speed" 2>/dev/null || true)"
    [[ "$speed" == "-1" || -z "$speed" ]] && speed=""
  fi
  if [[ -n "$speed" ]]; then
    HW[net_speed_mbps]="$speed"
    HW[net_speed_note]="网卡标称速率(虚拟网卡下可能不等于公网带宽)"
  else
    HW[net_speed_mbps]="UNAVAILABLE"
    HW[net_speed_note]="虚拟网卡无链路速率 —— 不得据此推算公网带宽(任务书 §2.3)"
    HW_RISK[net_speed]="虚拟网卡速率不可读, 公网带宽需用户指定或测速获得"
  fi

  # 队列（尽力）
  local queues
  if [[ -d "$ifdir/queues" ]]; then
    queues="$(ls "$ifdir/queues" 2>/dev/null | grep -cE 'rx\|tx' || true)"
    HW[net_queues]="${queues:-UNKNOWN}"
  else
    HW[net_queues]="UNAVAILABLE"
  fi

  # 收发统计
  if [[ -r "$TWO_BASE_PROC/net/dev" ]]; then
    local rx_byt tx_byt rx_pkts tx_pkts
    rx_byt="$(awk -v i="$default_iface" '$0 ~ i":"{print $3}' "$TWO_BASE_PROC/net/dev" 2>/dev/null || true)"
    tx_byt="$(awk -v i="$default_iface" '$0 ~ i":"{print $11}' "$TWO_BASE_PROC/net/dev" 2>/dev/null || true)"
    rx_pkts="$(awk -v i="$default_iface" '$0 ~ i":"{print $2}' "$TWO_BASE_PROC/net/dev" 2>/dev/null || true)"
    tx_pkts="$(awk -v i="$default_iface" '$0 ~ i":"{print $10}' "$TWO_BASE_PROC/net/dev" 2>/dev/null || true)"
    HW[net_rx_bytes]="${rx_byt:-0}"; HW[net_tx_bytes]="${tx_byt:-0}"
    HW[net_rx_packets]="${rx_pkts:-0}"; HW[net_tx_packets]="${tx_pkts:-0}"
    HW[net_stats_hrx]="$({ two_human_bytes "${HW[net_rx_bytes]}"; })"
    HW[net_stats_htx]="$({ two_human_bytes "${HW[net_tx_bytes]}"; })"
  else
    HW[net_stats_note]="无法读取 /proc/net/dev 统计"
  fi
  return 0
}

two_hw_detect_all() {
  two_hw_cpu
  two_hw_mem
  two_hw_net
  return 0
}
