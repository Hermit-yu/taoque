#!/usr/bin/env bash
# ============================================================================
# lib/configmgmt.sh — 参数生成与配置管理（任务书 §7）
#   - 只写独立文件 /etc/sysctl.d/90-tcp-window-optimizer.conf，绝不改 sysctl.conf
#   - 用显式管理标识(MARKER)包住本工具产生的行，识别旧配置、避免重复追加
#   - 每次修改前备份到 /etc/tcp-window-optimizer/backup/
#   - 记录修改前后参数
#   - 支持完整恢复 + 语法检查
#   - 检查 sysctl.d 现存重复/优先级冲突
# ============================================================================

declare -gA CFG=()

# 确保目录结构（§7）
two_cfg_ensure_dirs() {
  local base="${TWO_ROOT}"
  local d
  for d in "$base/config" "$base/backup" "$base/reports" "$base/logs"; do
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null || two_log_if WARN "无法创建目录 $d"
  done
  CFG[backup_dir]="$base/backup"
  CFG[reports_dir]="$base/reports"
  CFG[log_file]="$base/logs/run.log"
  return 0
}

# 冲突检查：其他 sysctl.d 文件是否定义了同名 key（优先级高于本工具的 90- 才会覆盖）
two_cfg_check_conflicts() {
  # 只提示，不阻断
  CFG[conflicts]=""
  local d
  for d in /etc/sysctl.d/*.conf /etc/sysctl.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
    [[ -r "$d" || -L "$d" ]] || continue
    case "$d" in
      *90-tcp-window-optimizer.conf) continue;;
    esac
    local f
    for f in net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max net.ipv4.tcp_window_scaling net.ipv4.tcp_moderate_rcvbuf; do
      # 排除注释行
      if grep -qE "^#?[[:space:]]*${f//./\.}[[:space:]]*=" "$d" 2>/dev/null; then
        CFG[conflicts]+="  - $f 同时定义于 $d"$'\n'
      fi
    done
  done
  if [[ -n "${CFG[conflicts]}" ]]; then
    CFG[conflict_note]="检测到与现存 sysctl 配置的同名定义。本工具文件 90- 命名数字较大(后加载)可能覆盖同名低优先级项；加载顺序以 sysctl 实际解析为准，应用后须用 --verify 核对实际生效值。"
    two_log_if WARN "检测到配置冲突:"
  else
    CFG[conflict_note]="未发现同名参数冲突"
  fi
  return 0
}

# 生成待应用配置内容（stdout），带管理标识
two_cfg_render() {
  # 依赖 REC 已计算
  cat <<EOF
$TWO_MARKER
# 本块由 TCP Window Optimizer 生成 ($(date '+%F %T'))
# 档位: ${REC[tier_name]}  BDP=${REC[bdp_mib]}MiB  带宽=${NET[bandwidth_mbps]}Mbps  RTT=${NET[rtt_ms]}ms
# 修改本块请重新运行 tcp-window-optimizer.sh，勿手改。回滚: ./tcp-window-optimizer.sh --rollback
# ============================================================================
EOF
  # 逐参数输出，只写内核支持且确实需要的
  two_cfg_write_param net.ipv4.tcp_window_scaling "${REC[window_scaling]}"
  two_cfg_write_param net.ipv4.tcp_rmem "${REC[rmem]}"
  two_cfg_write_param net.ipv4.tcp_wmem "${REC[wmem]}"
  two_cfg_write_param net.core.rmem_max "${REC[rmem_max]}"
  two_cfg_write_param net.core.wmem_max "${REC[wmem_max]}"
  if [[ -n "${REC[moderate_rcvbuf]:-}" ]]; then
    two_cfg_write_param net.ipv4.tcp_moderate_rcvbuf "${REC[moderate_rcvbuf]}"
  fi
  cat <<EOF
$TWO_MARKER_END
EOF
  return 0
}

# 单个参数写出行；内核不支持则跳过并注释说明（任务书 §3）
two_cfg_write_param() {
  local key="$1" val="$2"
  if two_param_supported "$key"; then
    printf '%s = %s\n' "$key" "$val"
  else
    printf '# [跳过] %s 当前内核不支持(%s)\n' "$key" "$key"
    CFG[skipped]+"$key "
  fi
}

# 备份"当前原始 sysctl 配置"到 backup/（仅备份本工具将影响的 key 的当前值 + 整个 90- 文件若存在）
two_cfg_backup_current() {
  two_cfg_ensure_dirs
  local ts; ts="$(date '+%Y%m%d-%H%M%S')"
  CFG[backup_file]="/orig-sysctl-$ts.txt"
  : > "${CFG[backup_file]}" 2>/dev/null || { two_log_if WARN "无法写备份文件"; return 1; }
  local key
  # 记录本工具会触碰的 key 的"当前实际值"（供回滚时精确恢复）
  for key in net.ipv4.tcp_window_scaling net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
            net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
            net.ipv4.tcp_moderate_rcvbuf; do
    local cur; cur="$(two_tcp_get "$key")"
    printf '%s = %s\n' "$key" "$cur" >> "${CFG[backup_file]}" 2>/dev/null
  done
  # 若已有本工具生成的 conf，也整份备份
  if [[ -r "$TWO_CONF" ]]; then
    cp -f "$TWO_CONF" "/prev-tcp-window-optimizer-$ts.conf" 2>/dev/null || true
    CFG[backup_prev_conf]="/prev-tcp-window-optimizer-$ts.conf"
  fi
  CFG[ts]="$ts"
  two_log_if INFO "已备份当前参数到 ${CFG[backup_file]}"
  return 0
}

# 写入独立配置（幂等：先删旧块再写，避免重复追加）
two_cfg_write_conf() {
  two_cfg_ensure_dirs
  CFG[skipped]=""
  local content; content="$(two_cfg_render)"
  if [[ -e "$TWO_CONF" ]]; then
    # 只管理自己：删除旧的 managed block（若存在），保留其余行
    local tmp="${TWO_CONF}.tmp"
    awk -v s="$TWO_MARKER" -v e="$TWO_MARKER_END" '
      $0==s{inblk=1; next}
      $0==e{inblk=0; next}
      !inblk{print}
    ' "$TWO_CONF" > "$tmp" 2>/dev/null
    cat > "$TWO_CONF" 2>/dev/null <<EOF
$(cat "$tmp")
$(echo "$content")
EOF
    rm -f "$tmp" 2>/dev/null
  else
    printf '%s\n' "$content" > "$TWO_CONF" 2>/dev/null
  fi
  [[ -w "$TWO_CONF" || -e "$TWO_CONF" ]] || { two_log_if ERROR "无法写入 $TWO_CONF (权限?)"; return 1; }
  two_log_if INFO "已写入独立配置 $TWO_CONF（跳过: ${CFG[skipped]:-无}）"
  return 0
}

# 配置语法检查（值数量 / 格式）
two_cfg_syntax_check() {
  # 对渲染出的内容做基本校验：每行 key = val，rmem/wmem 三值
  local content; content="$(two_cfg_render)"
  local bad=0 line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "#"* ]] && continue
    if [[ ! "$line" =~ ^[a-z.]+[[:space:]]*=[[:space:]]*.+$ ]]; then
      two_log_if WARN "语法可疑行: $line"; bad=1
    fi
  done <<< "$content"
  # rmem/wmem 必须是 3 个整数
  for kv in "${REC[rmem]}" "${REC[wmem]}"; do
    local n; n="$(echo "$kv" | wc -w | tr -d ' ')"
    [[ "$n" == "3" ]] || { two_log_if ERROR "rmem/wmem 非三值: $kv"; bad=1; }
  done
  (( bad == 0 )) && two_log_if INFO "配置语法检查通过" || two_log_if ERROR "配置语法检查未通过"
  return $bad
}
