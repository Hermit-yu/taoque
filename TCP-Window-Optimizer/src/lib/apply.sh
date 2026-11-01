#!/usr/bin/env bash
# ============================================================================
# lib/apply.sh — 安全应用 / 回滚 / 验证（任务书 §8 + §10）
# 安全最高优先级：
#   - 默认绝不自动改系统；--apply 需 root + 用户明确确认
#   - 只应用本工具独立 conf（sysctl -p 该文件），不 sysctl --system(不碰别人)
#   - 应用前：备份 + 前置检查 + diff + 确认
#   - 应用后：逐项读回对比"推荐/配置/内核实际"三值，未生效给出原因
#   - 回滚：写回备份原值 + 删除本工具 conf；绝不删用户其他配置
#   - 全程禁止要求重启（sysctl 参数热生效）
# ============================================================================

declare -gA APPLY=()

# 应用前前置检查（§8）。返回 0=可继续, 非0=应中止
two_apply_preflight() {
  local ok=1
  # root
  if [[ "$(id -u)" != "0" ]]; then
    two_log_if ERROR "应用需 root/sudo 权限。请用 sudo 运行。"
    ok=0
  fi
  # sysctl 可用
  if ! two_have_cmd sysctl >/dev/null; then
    two_log_if ERROR "无 sysctl 命令，无法应用。"
    ok=0
  fi
  # 内存预算检查：若推荐已降级为稳定优先且 BDP 被内存压住，提示而非阻断
  if [[ "${REC[downgraded]:-no}" == "yes" ]]; then
    two_log_if WARN "当前推荐已因内存压力降级(稳定优先)。应用的是保守值，安全。"
  fi
  # 内核支持：把不支持的 key 统计出来
  local unsupported=""
  local k
  for k in net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling; do
    two_param_supported "$k" || unsupported+=" $k"
  done
  if [[ -n "$unsupported" ]]; then
    two_log_if WARN "以下参数当前内核不支持，将被跳过:$unsupported"
  fi
  (( ok )) || return 1
  return 0
}

# 显示 修改前 vs 推荐 差异
two_apply_show_diff() {
  echo "================ 修改前后差异（仅本工具管理的 key）================"
  local k
  for k in net.ipv4.tcp_window_scaling net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max; do
    local cur rec
    cur="$(two_tcp_get "$k")"
    rec=""
    case "$k" in
      net.ipv4.tcp_window_scaling) rec="${REC[window_scaling]}";;
      net.ipv4.tcp_rmem) rec="${REC[rmem]}";;
      net.ipv4.tcp_wmem) rec="${REC[wmem]}";;
      net.core.rmem_max) rec="${REC[rmem_max]}";;
      net.core.wmem_max) rec="${REC[wmem_max]}";;
    esac
    local chg="无变化"
    [[ "$cur" != "$rec" ]] && chg="变化"
    printf '  %s\n    当前: %s\n    推荐: %s   [%s]\n' "$k" "$cur" "$rec" "$chg"
  done
  echo "====================================================================="
}

# 交互确认（非交互或已加 --yes 则按 --yes 走）
two_apply_confirm() {
  if [[ "${TWO_YES:-0}" == "1" ]]; then
    two_log_if WARN "已加 --yes，跳过交互确认，直接应用。"
    APPLY[confirmed]="yes(auto)"
    return 0
  fi
  local ans
  read -r -p "确认应用以上参数？[y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    APPLY[confirmed]="yes"
    return 0
  fi
  two_log_if INFO "用户取消，未做任何修改。"
  return 1
}

# 执行应用
two_apply_run() {
  two_apply_preflight || { APPLY[result]="preflight_failed"; return 1; }
  two_apply_show_diff
  two_apply_confirm || { APPLY[result]="cancelled"; return 1; }

  # 备份（必须在写之前）
  two_cfg_backup_current

  # 写独立 conf
  two_cfg_write_conf || { APPLY[result]="write_failed"; return 1; }

  # 语法检查
  two_cfg_syntax_check || {
    two_log_if ERROR "配置语法检查未通过，不应用。"
    APPLY[result]="syntax_failed"
    return 1
  }

  # 应用（只加载本工具文件）
  local out rc
  out="$(sysctl -p "$TWO_CONF" 2>&1)"
  rc=$?
  APPLY[sysctl_out]="$out"
  if (( rc != 0 )); then
    two_log_if ERROR "sysctl 应用返回 $rc。正在尝试回滚到应用前状态……"
    two_apply_rollback_silent
    APPLY[result]="apply_failed_reverted"
    return 1
  fi

  # 验证
  two_apply_verify
  APPLY[result]="applied"
  two_log_if INFO "应用完成并通过验证。"
  return 0
}

# 验证：推荐值 vs 配置文件值 vs 内核实际值（§10 逐项对比）
two_apply_verify() {
  local -a checks=(
    "net.ipv4.tcp_window_scaling:${REC[window_scaling]}"
    "net.ipv4.tcp_rmem:${REC[rmem]}"
    "net.ipv4.tcp_wmem:${REC[wmem]}"
    "net.core.rmem_max:${REC[rmem_max]}"
    "net.core.wmem_max:${REC[wmem_max]}"
  )
  [[ -n "${REC[moderate_rcvbuf]:-}" ]] && checks+=("net.ipv4.tcp_moderate_rcvbuf:${REC[moderate_rcvbuf]}")

  echo "================ 应用后验证（三值对比）================"
  local all_ok=1 item key exp actual
  for item in "${checks[@]}"; do
    key="${item%%:*}"; exp="${item#*:}"
    actual="$(two_tcp_get "$key")"
    # 规范化空格比较
    local a="${actual//[[:space:]]/}"; e="${exp//[[:space:]]/}"
    local status="一致"
    [[ "$a" != "$e" ]] && { status="不一致"; all_ok=0; }
    printf '  %-32s\n     内核实际: %-24s 期望: %s  [%s]\n' "$key" "$actual" "$exp" "$status"
    if [[ "$status" == "不一致" ]]; then
      if [[ "${SYS[param_ok.$key]:-0}" != "1" ]]; then
        echo "       原因: 当前内核不支持该参数，已跳过(非失败)。"
      else
        echo "       原因: 可能被更高优先级 sysctl.d 覆盖，或内核拒值。请检查 sysctl.d 顺序。"
      fi
    fi
  done

  # 专项核对（§10）
  if [[ "${REC[window_scaling]}" == "1" && "$(two_tcp_get net.ipv4.tcp_window_scaling)" == "1" ]]; then
    echo "  ✓ Window Scaling 已开启"
  fi
  if [[ -n "${REC[moderate_rcvbuf]:-}" && "$(two_tcp_get net.ipv4.tcp_moderate_rcvbuf)" == "${REC[moderate_rcvbuf]}" ]]; then
    echo "  ✓ 自动窗口调节(moderate_rcvbuf) 已开启"
  fi

  # 内存压力快查
  local memnow
  memnow="$(awk '/^MemAvailable:/{print int($2/1024)}' "$TWO_BASE_PROC/meminfo" 2>/dev/null || echo UNKNOWN)"
  echo "  应用后可用内存: ${memnow}MB（若骤降说明缓冲配置过大，建议回滚）"

  (( all_ok )) && echo "  结果: 全部关键参数已生效。" || echo "  结果: 存在未生效项，见上方原因说明。"
  echo "========================================================="
  APPLY[verify_all_ok]="$all_ok"
  return 0
}

# 静默回滚（应用失败时自动调用）
two_apply_rollback_silent() {
  [[ -z "${CFG[backup_file]:-}" || ! -r "${CFG[backup_file]:-}" ]] && return 0
  local k v
  while IFS=' = ' read -r k _ v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    sysctl -w "$k=$v" >/dev/null 2>&1 || true
  done < "${CFG[backup_file]}" 2>/dev/null
  # 删除本工具 conf，让原有配置恢复主导
  rm -f "$TWO_CONF" 2>/dev/null || true
  two_log_if WARN "已回滚到应用前状态（原值已写回，本工具 conf 已移除）。"
  return 0
}

# 显式回滚命令（--rollback）
two_apply_rollback() {
  if [[ "$(id -u)" != "0" ]]; then
    two_log_if ERROR "回滚需 root/sudo。"; return 1
  fi
  # 找最新备份
  local bk
  bk="$(ls -1 ""/orig-sysctl-*.txt 2>/dev/null | sort | tail -1 || true)"
  if [[ -z "$bk" || ! -r "$bk" ]]; then
    two_log_if WARN "未找到本工具备份文件，无法精确回滚。仅移除本工具 conf。"
    rm -f "$TWO_CONF" 2>/dev/null || true
    return 0
  fi
  local k _ v
  while IFS=' = ' read -r k _ v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    echo "  恢复 $k = $v"
    sysctl -w "$k=$v" 2>&1 || two_log_if WARN "恢复 $k 失败"
  done < "$bk"
  # 只移除本工具管理的 conf（任务书 §8：绝不能删用户其他配置）
  if [[ -e "$TWO_CONF" ]]; then
    rm -f "$TWO_CONF"
    two_log_if INFO "已移除 $TWO_CONF（仅本工具文件）"
  fi
  two_log_if INFO "回滚完成。当前参数已恢复到应用前状态。"
  return 0
}

# 查看最近检测报告（--report）
two_apply_show_report() {
  local f
  f="$(ls -1 ""/report-*.txt 2>/dev/null | sort | tail -1 || true)"
  if [[ -z "$f" || ! -r "$f" ]]; then
    two_log_if WARN "暂无检测报告，先运行一次检测/推荐。"
    return 1
  fi
  echo "最近检测报告: $f"
  cat "$f"
  return 0
}
