#!/bin/bash
# Network-VNO-AI 阶段 1：TCP/IP 深度诊断模块（tcp_detect.sh）
# 任务书第 5 章：TCP Window（5.1）/ 拥塞控制（5.2）/ 连接状态（5.3）/ 其他参数（5.4）
# 规则：纯 Bash；依赖逐项探测；失败不崩溃；默认只读；大白话；统一 JSON 到 data/tcp_detect_result.json。
# 所有路径走 common.sh（PROC_ROOT 可重定向，便于测试）。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="TCP/IP 深度诊断"
JSON_FILE="${DATA_DIR}/tcp_detect_result.json"

# 从 /proc/net/sockstat 的 TCP 行按标签取值，例如取 tw / inuse / mem
sockstat_tcp_field() {
    local label="$1"
    [[ -r "${PROC_ROOT}/net/sockstat" ]] || { echo "0"; return; }
    awk -v lab="$label" '$1=="TCP:"{for(i=2;i<=NF;i++) if($i==lab){print $(i+1); exit}}' "${PROC_ROOT}/net/sockstat" 2>/dev/null || echo "0"
}
# 从 /proc/net/snmp 的 Tcp 行按标签取值（CurrEstab/EstabResets/AttemptFails/RetransSegs/InErr）
# 说明：snmp 标签行与数值行「同列对齐」——标签只在表头行出现，数值行同位置是数字。
# 做法：表头行记录标签列号 idx，数值行取同列号字段。
snmp_tcp_field() {
    local label="$1"
    [[ -r "${PROC_ROOT}/net/snmp" ]] || { echo "0"; return; }
    awk -v lab="$label" '
        $1=="Tcp:" { if(!seen){ for(i=1;i<=NF;i++) if($(i)==lab) idx=i; seen=1 } else { if(idx>0) print $idx; exit } }
    ' "${PROC_ROOT}/net/snmp" 2>/dev/null || echo "0"
}
# 从 /proc/net/netstat 的 TcpExt 行按标签取值（ListenOverflows/ListenDrops/TCPMemoryPressures 等）
netstat_tcpext_field() {
    local label="$1"
    [[ -r "${PROC_ROOT}/net/netstat" ]] || { echo "0"; return; }
    awk -v lab="$label" '
        $1=="TcpExt:" { if(!seen){ for(i=1;i<=NF;i++) if($(i)==lab) idx=i; seen=1 } else { if(idx>0) print $idx; exit } }
    ' "${PROC_ROOT}/net/netstat" 2>/dev/null || echo "0"
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在读取 TCP 相关内核参数与连接状态（只读）..."

    # ---------------- 5.1 TCP Window 核心参数 ----------------
    tcp_window_scaling=$(read_sysctl net.ipv4.tcp_window_scaling)
    tcp_rmem=$(read_sysctl net.ipv4.tcp_rmem)
    tcp_wmem=$(read_sysctl net.ipv4.tcp_wmem)
    rmem_max=$(read_sysctl net.core.rmem_max)
    wmem_max=$(read_sysctl net.core.wmem_max)
    rmem_default=$(read_sysctl net.core.rmem_default)
    wmem_default=$(read_sysctl net.core.wmem_default)
    tcp_moderate_rcvbuf=$(read_sysctl net.ipv4.tcp_moderate_rcvbuf)
    # 解析 rmem/wmem 三元组
    rmem_min=$(echo "$tcp_rmem" | awk '{print $1}'); rmem_def=$(echo "$tcp_rmem" | awk '{print $2}'); rmem_max_cur=$(echo "$tcp_rmem" | awk '{print $3}')
    wmem_min=$(echo "$tcp_wmem" | awk '{print $1}'); wmem_def=$(echo "$tcp_wmem" | awk '{print $2}'); wmem_max_cur=$(echo "$tcp_wmem" | awk '{print $3}')

    # ---------------- 5.4 其他 TCP 参数 ----------------
    tcp_sack=$(read_sysctl net.ipv4.tcp_sack)
    tcp_dsack=$(read_sysctl net.ipv4.tcp_dsack)
    tcp_timestamps=$(read_sysctl net.ipv4.tcp_timestamps)
    tcp_fastopen=$(read_sysctl net.ipv4.tcp_fastopen)
    tcp_mtu_probing=$(read_sysctl net.ipv4.tcp_mtu_probing)
    tcp_no_metrics_save=$(read_sysctl net.ipv4.tcp_no_metrics_save)
    tcp_autocorking=$(read_sysctl net.ipv4.tcp_autocorking)
    tcp_limit_output_bytes=$(read_sysctl net.ipv4.tcp_limit_output_bytes)
    tcp_mem=$(read_sysctl net.ipv4.tcp_mem)
    tcp_adv_win_scale=$(read_sysctl net.ipv4.tcp_adv_win_scale)
    tcp_app_win=$(read_sysctl net.ipv4.tcp_app_win)

    # ---------------- 5.2 拥塞控制 ----------------
    tcp_cc=$(read_sysctl net.ipv4.tcp_congestion_control)
    tcp_cc_avail=$(read_sysctl net.ipv4.tcp_available_congestion_control)
    default_qdisc=$(read_sysctl net.core.default_qdisc)
    # BBR 实际注册状态（需求2：必须检查实际注册，不能仅看内核版本）
    bbr_registered="未注册"
    [[ "$tcp_cc_avail" == *"bbr"* ]] && bbr_registered="已注册（在 available 列表中）" || bbr_registered="未注册（available 列表无 bbr）"
    # BBR 模块是否加载
    bbr_loaded="未加载"
    if have_cmd lsmod; then
        lsmod 2>/dev/null | grep -q 'tcp_bbr' && bbr_loaded="已加载" || bbr_loaded="未加载（模块未激活）"
    elif [[ -r "${PROC_ROOT}/modules" ]]; then
        grep -q 'tcp_bbr' "${PROC_ROOT}/modules" 2>/dev/null && bbr_loaded="已加载" || bbr_loaded="未加载"
    fi
    # 适用性分析（需求2：不把 BBR 当万能；结合实际条件）
    cc_analysis=""
    case "$tcp_cc" in
        *bbr*) cc_analysis="当前为 BBR：适合高带宽/高 RTT/长肥管道；低延迟短连接场景未必优于 CUBIC，需结合实际测速判断，不应盲目替换。" ;;
        *cubic*) cc_analysis="当前为 CUBIC：Linux 默认，绝大多数场景稳定可靠，是稳妥的基准算法。" ;;
        *reno*) cc_analysis="当前为 Reno：经典算法，适合低带宽低延迟，高 BDP 场景吞吐受限。" ;;
        *) cc_analysis="当前为 ${tcp_cc:-未知}：建议结合实际业务与测速判断适用性。" ;;
    esac

    # ---------------- 5.3 连接状态 ----------------
    tcp_estab=$(snmp_tcp_field CurrEstab)
    tcp_estab_resets=$(snmp_tcp_field EstabResets)
    tcp_attempt_fails=$(snmp_tcp_field AttemptFails)
    tcp_retrans=$(snmp_tcp_field RetransSegs)
    tcp_inerr=$(snmp_tcp_field InErr)
    tcp_time_wait=$(sockstat_tcp_field tw)
    tcp_inuse=$(sockstat_tcp_field inuse)
    tcp_orphan=$(sockstat_tcp_field orphan)
    tcp_mem_pressure=$(netstat_tcpext_field TCPMemoryPressures)
    tcp_listen_overflow=$(netstat_tcpext_field ListenOverflows)
    tcp_listen_drops=$(netstat_tcpext_field ListenDrops)
    # 若 ss 可用，用 ss 补充状态计数（更准）
    ss_estab=0; ss_time_wait=0; ss_close_wait=0; ss_syn_recv=0
    if have_cmd ss; then
        # 一次捕获复用；用 awk 计数，避免 grep -c 无匹配时「输出 0 且退出码 1」触发 || echo 0 叠加成 "0\n0"，污染 JSON
        ss_out="$(ss -tan 2>/dev/null)"
        ss_estab=$(printf '%s\n' "$ss_out"      | awk '/ESTAB/{c++}END{print c+0}')
        ss_time_wait=$(printf '%s\n' "$ss_out"  | awk '/TIME-WAIT/{c++}END{print c+0}')
        ss_close_wait=$(printf '%s\n' "$ss_out" | awk '/CLOSE-WAIT/{c++}END{print c+0}')
        ss_syn_recv=$(printf '%s\n' "$ss_out"   | awk '/SYN-RECV/{c++}END{print c+0}')
    fi
    # 优先使用 ss 计数（更贴近实际 socket 状态），否则用内核统计
    [[ "$ss_estab" -gt 0 ]] && tcp_estab="$ss_estab"
    [[ "$ss_time_wait" -gt 0 ]] && tcp_time_wait="$ss_time_wait"

    # ---------------- 输出（大白话） ----------------
    echo "TCP/IP 诊断完成："
    vno_log INFO "Window Scaling=${tcp_window_scaling:-未知}；自动窗口调节(moderate_rcvbuf)=${tcp_moderate_rcvbuf:-未知}"
    vno_log INFO "tcp_rmem 当前（min/def/max）= ${tcp_rmem:-未知}；tcp_wmem = ${tcp_wmem:-未知}"
    vno_log INFO "全局：rmem_max=${rmem_max:-未知}，wmem_max=${wmem_max:-未知}，rmem_default=${rmem_default:-未知}，wmem_default=${wmem_default:-未知}"
    vno_log INFO "其他：sack=${tcp_sack:-?} timestamps=${tcp_timestamps:-?} fastopen=${tcp_fastopen:-?} mtu_probing=${tcp_mtu_probing:-?} no_metrics_save=${tcp_no_metrics_save:-?} limit_output_bytes=${tcp_limit_output_bytes:-?}"
    vno_log INFO "拥塞控制：当前=${tcp_cc:-未知}；可选=[${tcp_cc_avail:-未知}]；默认qdisc=${default_qdisc:-未知}"
    vno_log INFO "BBR 状态：注册=${bbr_registered}；模块加载=${bbr_loaded}"
    vno_log INFO "连接：ESTABLISHED≈${tcp_estab} TIME_WAIT≈${tcp_time_wait} CLOSE_WAIT≈${ss_close_wait} SYN_RECV≈${ss_syn_recv} orphan≈${tcp_orphan}"
    vno_log INFO "异常指标：重传=${tcp_retrans} 连接重置=${tcp_estab_resets} 建立失败=${tcp_attempt_fails} 入错=${tcp_inerr} Listen溢出=${tcp_listen_overflow} Listen丢弃=${tcp_listen_drops} TCP内存压力=${tcp_mem_pressure}"
    vno_log INFO "诊断建议：${cc_analysis}（TIME_WAIT 高需结合业务规模判断，不能直接认定异常）"

    # ---------------- 写入 JSON ----------------
    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"tcp_detect\","
      echo "  \"stage\": 1,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"tcp_window\": {"
      echo "    \"tcp_window_scaling\": \"${tcp_window_scaling:-未知}\","
      echo "    \"tcp_moderate_rcvbuf\": \"${tcp_moderate_rcvbuf:-未知}\","
      echo "    \"tcp_rmem_raw\": \"$(sanitize_json "$tcp_rmem")\","
      echo "    \"tcp_rmem_min\": ${rmem_min:-0},"
      echo "    \"tcp_rmem_default\": ${rmem_def:-0},"
      echo "    \"tcp_rmem_max\": ${rmem_max_cur:-0},"
      echo "    \"tcp_wmem_raw\": \"$(sanitize_json "$tcp_wmem")\","
      echo "    \"tcp_wmem_min\": ${wmem_min:-0},"
      echo "    \"tcp_wmem_default\": ${wmem_def:-0},"
      echo "    \"tcp_wmem_max\": ${wmem_max_cur:-0},"
      echo "    \"rmem_max\": ${rmem_max:-0},"
      echo "    \"wmem_max\": ${wmem_max:-0},"
      echo "    \"rmem_default\": ${rmem_default:-0},"
      echo "    \"wmem_default\": ${wmem_default:-0}"
      echo "  },"
      echo "  \"tcp_other\": {"
      echo "    \"tcp_sack\": \"${tcp_sack:-未知}\","
      echo "    \"tcp_dsack\": \"${tcp_dsack:-未知}\","
      echo "    \"tcp_timestamps\": \"${tcp_timestamps:-未知}\","
      echo "    \"tcp_fastopen\": \"${tcp_fastopen:-未知}\","
      echo "    \"tcp_mtu_probing\": \"${tcp_mtu_probing:-未知}\","
      echo "    \"tcp_no_metrics_save\": \"${tcp_no_metrics_save:-未知}\","
      echo "    \"tcp_autocorking\": \"${tcp_autocorking:-未知}\","
      echo "    \"tcp_limit_output_bytes\": \"${tcp_limit_output_bytes:-未知}\","
      echo "    \"tcp_adv_win_scale\": \"${tcp_adv_win_scale:-未知}\","
      echo "    \"tcp_app_win\": \"${tcp_app_win:-未知}\","
      echo "    \"tcp_mem_raw\": \"$(sanitize_json "$tcp_mem")\""
      echo "  },"
      echo "  \"congestion_control\": {"
      echo "    \"current_algorithm\": \"$(sanitize_json "$tcp_cc")\","
      echo "    \"available_algorithms\": \"$(sanitize_json "$tcp_cc_avail")\","
      echo "    \"default_qdisc\": \"$(sanitize_json "$default_qdisc")\","
      echo "    \"bbr_registered\": \"$(sanitize_json "$bbr_registered")\","
      echo "    \"bbr_module_loaded\": \"$(sanitize_json "$bbr_loaded")\","
      echo "    \"analysis_note\": \"$(sanitize_json "$cc_analysis")\""
      echo "  },"
      echo "  \"tcp_connections\": {"
      echo "    \"established\": ${tcp_estab:-0},"
      echo "    \"time_wait\": ${tcp_time_wait:-0},"
      echo "    \"close_wait\": ${ss_close_wait:-0},"
      echo "    \"syn_recv\": ${ss_syn_recv:-0},"
      echo "    \"inuse\": ${tcp_inuse:-0},"
      echo "    \"orphan\": ${tcp_orphan:-0},"
      echo "    \"retrans_segs\": ${tcp_retrans:-0},"
      echo "    \"estab_resets\": ${tcp_estab_resets:-0},"
      echo "    \"attempt_fails\": ${tcp_attempt_fails:-0},"
      echo "    \"in_errors\": ${tcp_inerr:-0},"
      echo "    \"listen_overflows\": ${tcp_listen_overflow:-0},"
      echo "    \"listen_drops\": ${tcp_listen_drops:-0},"
      echo "    \"tcp_mem_pressure\": ${tcp_mem_pressure:-0},"
      echo "    \"note\": \"TIME_WAIT 偏高需结合业务规模判断，不能直接认定异常\""
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"TCP/IP 深度诊断完成，未修改任何内核参数\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存 TCP 诊断数据到 ${JSON_FILE}"
    echo "阶段 1 模块 tcp_detect 完成。"
}

main "$@"
