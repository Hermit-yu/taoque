#!/usr/bin/env bash
# ============================================================================
# lib/report.sh — 中文检测报告（任务书 §11）
# 依赖：HW/SYS/TCP/NET/REC/CFG 已填充。
# 纪律：禁止虚构优化百分比；未测得的数据标 UNKNOWN；只给"改善方向"
# ============================================================================

declare -gA RPT=()
# CFG 由 configmgmt.sh 提供；若未先 source，two_report_generate 内做最小兜底

# 参数状态三态判定
two_state_recvbuf() {
  # rmem_max 与 BDP 对比
  local max="${TCP[rmem_max]:-0}" bdp="${REC[bdp_bytes]:-0}"
  two_is_uint "$max" || max=0
  (( bdp <= 0 )) && { echo "需要评估"; return 0; }
  if (( max >= bdp )); then
    echo "正常(≥BDP)"
  elif (( max * 2 >= bdp )); then
    echo "偏低(约 BDP 一半, 建议评估)"
  else
    echo "不足(远小于 BDP, 高带宽高RTT下可能限制吞吐)"
  fi
}
two_state_sendbuf() {
  local max="${TCP[wmem_max]:-0}" bdp="${REC[bdp_bytes]:-0}"
  two_is_uint "$max" || max=0
  (( bdp <= 0 )) && { echo "需要评估"; return 0; }
  if (( max >= bdp )); then echo "正常(≥BDP)"
  elif (( max * 2 >= bdp )); then echo "偏低(建议评估)"
  else echo "不足(可能影响发送端吞吐)"; fi
}

# 生成报告到 stdout，同时落盘
two_report_generate() {
  # 最小兜底：若 CFG 未填充，用 TWO_ROOT 计算
  local root_dir="${TWO_ROOT:-/etc/tcp-window-optimizer}"
  local outfile="$root_dir/reports/report-$(date '+%Y%m%d-%H%M%S').txt"
  mkdir -p "$root_dir/reports" 2>/dev/null || true
  {
  echo "======================================================================"
  echo "          TCP Window Optimizer — 检测报告"
  echo "  生成时间: $(date '+%F %T')    本机: $(hostname 2>/dev/null || echo unknown)"
  echo "======================================================================"

  echo; echo "【一、系统信息】"
  echo "  发行版        : ${SYS[distro]:-N/A}  (ID=${SYS[distro_id]:-N/A} ${SYS[distro_ver]:-N/A})"
  echo "  内核版本      : ${SYS[kernel]:-N/A}  (${SYS[karch]:-N/A})"
  echo "  systemd       : ${SYS[systemd]:-unknown}"
  echo "  sysctl        : ${SYS[sysctl]:-unknown}"
  echo "  CPU 型号      : ${HW[cpu_model]:-N/A}"
  echo "  CPU 核心      : 物理 ${HW[cpu_physical]:-0} / 逻辑 ${HW[cpu_logical]:-0}"
  echo "  虚拟化        : ${HW[cpu_virt]}"
  echo "  CPU 负载      : ${HW[load_avg]:-N/A}  (使用率 ${HW[cpu_usage]:-N/A})"
  echo "  内存总量      : ${HW[mem_total_mb]:-N/A}MB  [档位识别: ${HW[mem_tier]:-N/A}]"
  echo "  可用内存      : ${HW[mem_avail_mb]:-UNKNOWN}MB  ${HW[mem_avail_note]:-}"
  echo "  已用内存      : ${HW[mem_used_mb]:-UNKNOWN}MB (${HW[mem_used_pct]:-UNKNOWN}%)"
  echo "  Swap          : 总 ${HW[swap_total_mb]:-UNKNOWN}MB / 用 ${HW[swap_used_mb]:-UNKNOWN}MB"
  if [[ "${HW[mem_small]:-}" == "yes" ]]; then
    echo "  ⚠ 小内存 VPS(≤1GB)：已启用内存保护约束，缓冲区上限受限"
  fi

  echo; echo "【二、网卡信息】"
  echo "  默认路由网卡  : ${HW[net_iface]:-N/A}"
  echo "  MTU           : ${HW[net_mtu]:-N/A}"
  echo "  链路状态      : ${HW[net_state]:-N/A}"
  echo "  网卡速率      : ${HW[net_speed_mbps]:-N/A}  ${HW[net_speed_note]:-}"
  echo "  队列          : ${HW[net_queues]:-N/A}"
  echo "  收发统计      : 收 ${HW[net_stats_hrx]:-N/A} / 发 ${HW[net_stats_htx]:-N/A}"

  echo; echo "【三、网络环境】"
  echo "  公网带宽估计  : ${NET[bandwidth_mbps]:-N/A}Mbps  来源: ${NET[bandwidth_source]:-N/A}"
  echo "  RTT           : ${NET[rtt_ms]}ms  (目标 ${NET[rtt_target]:-N/A}, min=${NET[rtt_min]:-?} max=${NET[rtt_max]:-?} 抖动=${NET[rtt_jitter]:-?})"
  echo "  RTT 可信度    : ${NET[rtt_trust]:-N/A}  ${NET[rtt_note]:-}"
  echo "  数据来源分级  : ${NET[bandwidth_source]}"
  echo "  主动网速测试  : ${NET[speedtest_status]:-N/A}  速率=${NET[speedtest_mbps]:-N/A}Mbps  详情=${NET[speedtest_detail]:-}"
  echo "  iperf3 测速   : ${NET[iperf3_result]}"
  echo "  拥塞控制算法  : 当前=${SYS[cong_cur]:-N/A}  可用=${SYS[cong_avail]:-N/A}"

  echo; echo "【四、当前 TCP Window 状态】"
  echo "  Window Scaling  : $( [[ "${TCP[window_scaling]:-0}" == "1" ]] && echo "已开启" || echo "未开启(${TCP[window_scaling]:-0})" )"
  echo "  Receive Buffer  : $(two_state_recvbuf)   [当前 rmem: ${TCP[rmem]:-N/A}]"
  echo "  Send Buffer     : $(two_state_sendbuf)   [当前 wmem: ${TCP[wmem]:-N/A}]"
  echo "  自动窗口调节    : $( [[ "${TCP[moderate_rcvbuf]:-0}" == "1" ]] && echo "已开启" || echo "未开启" )   [moderate_rcvbuf=${TCP[moderate_rcvbuf]:-0}]"
  echo "  全局缓冲上限    : rmem_max=${TCP[rmem_max_global]:-N/A}  wmem_max=${TCP[wmem_max_global]:-N/A}"
  echo "  相关参数全量当前值:"
  local k
  for k in window_scaling rmem wmem rmem_max_global wmem_max_global rmem_default_global wmem_default_global moderate_rcvbuf no_metrics_save timestamps sack dsack congestion adv_win_scale app_win limit_output_bytes tcp_mem; do
    echo "    net${k} = ${TCP[$k]}" 2>/dev/null || echo "    $k = ${TCP[$k]}"
  done

  echo; echo "【五、推荐参数（逐项）】"
  echo "  档位: ${REC[tier_name]:-N/A}  BDP 理论值: ${REC[bdp_mib]:-0}MiB (仅参考)"
  printf '  %-34s | %-22s | %-22s | %s\n' "参数" "当前值" "推荐值" "变化/理由"
  echo "  ------------------------------------------------------------------"
  two_report_line net.ipv4.tcp_window_scaling "${TCP[window_scaling]:-0}" "${REC[window_scaling]}" "窗口缩放必须开启(高带宽前提)"
  two_report_line net.ipv4.tcp_rmem "${TCP[rmem]:-N/A}" "${REC[rmem]}" "BDP 与内存预算的自适应接收缓冲三元组"
  two_report_line net.ipv4.tcp_wmem "${TCP[wmem]:-N/A}" "${REC[wmem]}" "发送缓冲=接收的3/4, 降低内存峰值"
  two_report_line net.core.rmem_max "${TCP[rmem_max_global]:-N/A}" "${REC[rmem_max]:-N/A}" "全局接收上限, 支撑自动调节"
  two_report_line net.core.wmem_max "${TCP[wmem_max_global]:-N/A}" "${REC[wmem_max]:-N/A}" "全局发送上限"
  if [[ -n "${REC[moderate_rcvbuf]:-}" ]]; then
    two_report_line net.ipv4.tcp_moderate_rcvbuf "${TCP[moderate_rcvbuf]:-0}" "${REC[moderate_rcvbuf]:-N/A}" "启用自动接收缓冲调节"
  fi

  echo; echo "【六、计算过程（可追溯）】"
  local note
  for note in "${REC_NOTES[@]}"; do
    echo "  • $note"
  done
  echo "  • 未采用 BDP 直配: Linux 缓冲按需分配(on-demand), max 仅上限, 避免每连接预留"

  echo; echo "【七、安全评估】"
  echo "  内存风险      : $( [[ "${REC[downgraded]:-no}" == "yes" ]] && echo "中-高(已自动降级缓冲区)" || echo "低(预算内)" )"
  echo "  参数兼容性    : 不支持项已跳过: ${CFG[skipped]:-无}"
  echo "  配置冲突      : ${CFG[conflict_note]:-未检查}"
  echo "  推荐方案      : ${REC[tier_name]:-N/A} (档位字母 ${REC[tier]:-N/A})"
  echo "  是否允许应用  : $( [[ "${SYS[sysctl]:-}" == yes* ]] && echo "允许(需 --apply + root + 确认)" || echo "受限(sysctl 缺失)" )"
  # 强制禁区（§9）
  echo "  禁区参数      : 拥塞控制/netdev_max_backlog/somaxconn/max_syn_backlog/fin_timeout/ 等一律不动"

  echo; echo "【八、最终结论】"
  echo "  当前网络配置评价: $(two_report_verdict)"
  echo "  最值得关注      : $(two_report_top_focus)"
  echo "  推荐优化等级    : ${REC[tier_name]:-N/A}"
  echo "  预计改善方向    : 高 RTT 或大带宽场景下接收/发送缓冲达到 BDP 后, 链路利用率有改善空间"
  echo "                    (具体提升幅度需实测, 本报告不承诺百分比)"
  echo "  未验证假设      : ①带宽为${NET[bandwidth_source]:-N/A} ②RTT 可信度=${NET[rtt_trust]:-N/A}"
  echo "                    ③并发连接数按 ${REC[concurrency]:-N/A} 估算 ④内核升级后需重跑检测"
  echo
  echo "======================================================================"
  } | tee "$outfile"
  two_log_if INFO "报告已生成: $outfile"
  # 最小兜底：若 CFG 已声明则记录
  if [[ -n "${CFG[reports_dir]:-}" ]]; then CFG[last_report]="$outfile" 2>/dev/null || true; fi
  return 0
}

# 一行: 参数 | 当前 | 推荐 | 理由（带"变化/无变化"标注）
two_report_line() {
  local key="$1" cur="$2" rec="$3" reason="$4"
  local tag="无变化"
  [[ "$cur" != "$rec" ]] && tag="变化"
  printf '  %-34s | %-22s | %-22s | %s [%s]\n' "$key" "$cur" "$rec" "$reason" "$tag"
}

# 总体评价
two_report_verdict() {
  if [[ "${TCP[window_scaling]:-0}" != "1" ]]; then
    echo "基础项异常: Window Scaling 未开启, 高带宽场景受 64KiB 窗口限制, 建议优先修复"
    return 0
  fi
  local rv sv
  rv="$(two_state_recvbuf)"
  sv="$(two_state_sendbuf)"
  case "$rv" in
    *不足*|*偏低*) echo "接收缓冲相对当前 BDP 偏小, 是本机最可能的瓶颈";;
    *) case "$sv" in
        *不足*|*偏低*) echo "发送缓冲相对当前 BDP 偏小, 建议评估";;
        *) echo "基础项正常(窗口缩放/自动调节均已开启), 缓冲区与 BDP 大体匹配";;
      esac;;
  esac
}

# 最值得优化的参数
two_report_top_focus() {
  if [[ "${TCP[window_scaling]:-0}" != "1" ]]; then
    echo "net.ipv4.tcp_window_scaling (开启窗口缩放)"
  elif [[ "${TCP[moderate_rcvbuf]:-0}" != "1" ]]; then
    echo "net.ipv4.tcp_moderate_rcvbuf (启用自动调节)"
  else
    echo "net.ipv4.tcp_rmax / net.core.rmem_max (接收缓冲上限对齐 BDP)"
  fi
}

# 检测后打印"当前参数"菜单视图（§12 菜单 2 用）
two_report_status_view() {
  two_tcp_detect_all
  echo "当前 TCP 参数速览:"
  local k
  for k in window_scaling rmem wmem rmem_max_global wmem_max_global moderate_rcvbuf congestion; do
    echo "  ${k}: ${TCP[$k]}"
  done
}
