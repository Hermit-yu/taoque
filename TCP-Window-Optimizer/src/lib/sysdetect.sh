#!/usr/bin/env bash
# ============================================================================
# lib/sysdetect.sh — Linux 系统兼容性检测（任务书 §3）
# 输出全局：
#   SYS[distro] / SYS[distro_ver] / SYS[kernel] / SYS[karch]
#   SYS[systemd] / SYS[sysctl] / SYS[cong_cur] / SYS[cong_avail]
#   SYS[param_ok.<name>] = 1/0  各关键参数是否被当前内核支持
# 内核升级后调用本模块即可重新判断参数兼容性（任务书 §自适应重算）
# ============================================================================

declare -gA SYS=()

two_sys_detect() {
  # 发行版（/etc/os-release 优先，fixture 可注入 TWO_OS_RELEASE）
  local osrel="${TWO_OS_RELEASE:-/etc/os-release}"
  if [[ -r "$osrel" ]]; then
    # shellcheck disable=SC1090
    local pre="$osrel"; . "$osrel" 2>/dev/null || true
    SYS[distro]="${PRETTY_NAME:-$(cat "$osrel" 2>/dev/null | awk -F= '/ID=/{print $2}')}"
    SYS[distro_id]="${ID:-unknown}"
    SYS[distro_ver]="${VERSION_ID:-unknown}"
  else
    SYS[distro]="UNKNOWN"; SYS[distro_id]="unknown"; SYS[distro_ver]="UNKNOWN"
  fi

  SYS[kernel]="$(uname -r 2>/dev/null || echo UNKNOWN)"
  SYS[karch]="$(uname -m 2>/dev/null || echo UNKNOWN)"

  # systemd 可用性
  if two_have_cmd systemctl >/dev/null && systemctl is-system-running >/dev/null 2>&1; then
    SYS[systemd]="yes"
  elif two_have_cmd systemctl >/dev/null; then
    SYS[systemd]="present (服务未 running, 可能是容器/chroot)"
  else
    SYS[systemd]="no"; two_note_missing systemctl "无 systemd, 参数应用仍走 sysctl 生效(无需重启)"
  fi

  # sysctl 可用性
  if two_have_cmd sysctl >/dev/null; then
    SYS[sysctl]="yes ($(command -v sysctl))"
  else
    SYS[sysctl]="no"; two_note_missing sysctl "无 sysctl 命令, 将退化为直接读写 /proc/sys"
  fi

  # 拥塞控制：当前 + 可用
  SYS[cong_cur]="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat "$TWO_BASE_PROC/sys/net/ipv4/tcp_congestion_control" 2>/dev/null || echo UNKNOWN)"
  # 多算法(新内核)
  SYS[cong_avail]="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || cat "$TWO_BASE_PROC/sys/net/ipv4/tcp_available_congestion_control" 2>/dev/null || echo UNKNOWN)"
  [[ -n "${SYS[cong_avail]:-}" ]] || SYS[cong_avail]="${SYS[cong_cur]}"

  # 逐参数存在性探测（任务书：不支持的内核参数必须跳过并在报告说明）
  local -a probe_params=(
    net.ipv4.tcp_window_scaling
    net.ipv4.tcp_rmem
    net.ipv4.tcp_wmem
    net.core.rmem_max
    net.core.wmem_max
    net.core.rmem_default
    net.core.wmem_default
    net.ipv4.tcp_moderate_rcvbuf
    net.ipv4.tcp_no_metrics_save
    net.ipv4.tcp_timestamps
    net.ipv4.tcp_sack
    net.ipv4.tcp_dsack
    net.ipv4.tcp_congestion_control
    net.ipv4.tcp_adv_win_scale
    net.ipv4.tcp_app_win
    net.ipv4.tcp_limit_output_bytes
    net.ipv4.tcp_mem
  )
  local p procsysbase="${TWO_BASE_PROC}/sys/net"
  for p in "${probe_params[@]}"; do
    # 将 net.ipv4.tcp_rmem -> net/ipv4/tcp_rmem
    local rel="${p//.//}"
    if [[ -e "$procsysbase/$rel" ]]; then
      SYS[param_ok."$p"]=1
    elif two_have_cmd sysctl >/dev/null && sysctl -n "$p" >/dev/null 2>&1; then
      SYS[param_ok."$p"]=1
    else
      SYS[param_ok."$p"]=0
    fi
  done
  return 0
}

# 参数是否受支持（供计算/应用模块调用）
two_param_supported() {
  local p="$1"
  [[ "${SYS[param_ok.$p]:-0}" == "1" ]]
}
