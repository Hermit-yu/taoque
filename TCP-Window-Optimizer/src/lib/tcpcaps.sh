#!/usr/bin/env bash
# ============================================================================
# lib/tcpcaps.sh — TCP Window 核心参数检测（任务书 §4）
# 只读取当前生效值，绝不修改。输出全局：
#   TCP[<param>] = 当前值
# 四个概念严格区分（任务书 §2 追加强调）：
#   Window Scaling / Receive Buffer / Send Buffer / BDP 分别分析
# ============================================================================

declare -gA TCP=()

two_tcp_get() {
  # $1=参数名, 输出当前生效值（失败输出 UNKNOWN）
  local p="$1"
  local v
  if two_have_cmd sysctl >/dev/null; then
    v="$(sysctl -n "$p" 2>/dev/null)"
  else
    local rel="${p//.//}"
    v="$({ [[ -r "$TWO_BASE_PROC/sys/$rel" ]] && cat "$TWO_BASE_PROC/sys/$rel"; } 2>/dev/null || true)"
  fi
  if [[ -z "${v:-}" ]]; then
    v="UNKNOWN"
  fi
  printf '%s' "$v"
}

two_tcp_detect_all() {
  # 4.1 Window Scaling
  TCP[window_scaling]="$(two_tcp_get net.ipv4.tcp_window_scaling)"

  # 4.2 Receive Buffer (min default max)
  local rmem; rmem="$(two_tcp_get net.ipv4.tcp_rmem)"
  TCP[rmem]="$rmem"
  TCP[rmem_min]="$({ printf '%s\n' "$rmem" | awk '{print $1}'; })"
  TCP[rmem_def]="$({ printf '%s\n' "$rmem" | awk '{print $2}'; })"
  TCP[rmem_max]="$({ printf '%s\n' "$rmem" | awk '{print $3}'; })"

  # 4.3 Send Buffer
  local wmem; wmem="$(two_tcp_get net.ipv4.tcp_wmem)"
  TCP[wmem]="$wmem"
  TCP[wmem_min]="$({ printf '%s\n' "$wmem" | awk '{print $1}'; })"
  TCP[wmem_def]="$({ printf '%s\n' "$wmem" | awk '{print $2}'; })"
  TCP[wmem_max]="$({ printf '%s\n' "$wmem" | awk '{print $3}'; })"

  # 4.4 全局缓冲区
  TCP[rmem_max_global]="$(two_tcp_get net.core.rmem_max)"
  TCP[wmem_max_global]="$(two_tcp_get net.core.wmem_max)"
  TCP[rmem_default_global]="$(two_tcp_get net.core.rmem_default)"
  TCP[wmem_default_global]="$(two_tcp_get net.core.wmem_default)"

  # 4.5 自动窗口调节
  TCP[moderate_rcvbuf]="$(two_tcp_get net.ipv4.tcp_moderate_rcvbuf)"

  # 4.6 其他参数
  TCP[no_metrics_save]="$(two_tcp_get net.ipv4.tcp_no_metrics_save)"
  TCP[timestamps]="$(two_tcp_get net.ipv4.tcp_timestamps)"
  TCP[sack]="$(two_tcp_get net.ipv4.tcp_sack)"
  TCP[dsack]="$(two_tcp_get net.ipv4.tcp_dsack)"
  TCP[congestion]="$(two_tcp_get net.ipv4.tcp_congestion_control)"
  TCP[adv_win_scale]="$(two_tcp_get net.ipv4.tcp_adv_win_scale)"
  TCP[app_win]="$(two_tcp_get net.ipv4.tcp_app_win)"
  TCP[limit_output_bytes]="$(two_tcp_get net.ipv4.tcp_limit_output_bytes)"
  TCP[tcp_mem]="$(two_tcp_get net.ipv4.tcp_mem)"

  return 0
}

# 快速诊断三态（供报告 §11 "当前 TCP Window 状态"）
two_tcp_quick_state() {
  # 输出：Window Scaling / Receive Buffer / Send Buffer / 自动调节 各自的
  #   正常 / 需要评估 / 异常
  local ws=""; local out
  two_log_if INFO "诊断中…"
  # 这里只是占位说明：真正的三态在 report 层结合 BDP 计算判定
  return 0
}
