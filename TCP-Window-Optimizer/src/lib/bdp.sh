#!/usr/bin/env bash
# ============================================================================
# lib/bdp.sh — TCP Window 智能计算引擎（任务书 §6，核心）
# 依赖已填充：HW[mem_*], NET[rtt_ms], NET[bandwidth_mbps], SYS[mem_small]
# 输出：REC[rmem/wmem/rmem_max/wmem_max/tier/...] + REC_NOTES[] 计算过程
#
# 概念严格区分（任务书追加强调 §1）：
#   - BDP 只是"维持链路满速所需数据量"的参考值，绝不直接把缓冲区=BDP
#   - 缓冲区按需分配(on-demand)，max 是上限而非每条连接的预留量
#   - 小内存 VPS 禁止套用大内存/高带宽参数
#   - 稳定性 > 吞吐量
# ============================================================================

declare -gA REC=()
declare -ga REC_NOTES=()

# ---- 6.1 BDP 计算：bdp_bytes = bw(Mbps)*rtt(ms)*1000/8 ----
two_bdp_bytes() {
  # $1=bandwidth_mbps $2=rtt_ms → stdout 字节
  local bw="${1:-0}" rtt="${2:-0}"
  two_is_uint "${bw%%.*}" || bw=0
  two_is_uint "${rtt%%.*}" || rtt=0
  awk -v bw="$bw" -v rtt="$rtt" 'BEGIN{printf "%d", bw*rtt*1000/8}' 2>/dev/null || printf '0'
}

# 取 2 的幂向上取整到"整齐"值：把字节值 round up 到 2^n 的整倍数(MiB 对齐)
two_round_up_mib() {
  # 把字节值向上取整到 1MiB 的整数倍（缓冲区参数取整齐值更可控）
  local bytes="${1:-0}"
  (( bytes <= 0 )) && { printf '0'; return; }
  local mib
  mib=$(( (bytes + 1048575) / 1048576 ))
  (( mib < 1 )) && mib=1
  printf '%s' "$mib"
}

# ---- 6.2/6.3 推荐逻辑 + 分级 ----
two_calc_engine() {
  REC_NOTES=()
  REC=()

  local bw="${NET[bandwidth_mbps]:-0}"
  local rtt="${NET[rtt_ms]:-100}"
  # 显式标注：若带宽来自主动测速，则把测速状态写入计算说明
  local speed_ref=""
  [[ "${NET[speedtest_status]:-}" == "OK" ]] && speed_ref="(参考带宽=主动测速 ${NET[speedtest_mbps]}Mbps)"
  [[ "${NET[speedtest_status]:-}" == "INSUFFICIENT" ]] && speed_ref="(测速数据不足，已退回其他来源)"
  [[ "${NET[speedtest_status]:-}" == "FAILED"* ]] && speed_ref="(主动测速失败，已退回其他来源)"
  two_is_uint "${bw%%.*}" || bw="${TWO_DEFAULT_BANDWIDTH_Mbps:-100}"
  two_is_uint "${rtt%%.*}" || rtt="100"

  # 若 RTT 未测得，明确降级可信度并标注
  [[ "${NET[rtt_trust]:-}" == "unmeasured" ]] && two_log_if WARN "RTT 未测得，采用保守默认，计算结果可信度低"
  # 测速参考数据已纳入：带宽=${bw}Mbps，来源=${NET[bandwidth_source]:-}, 延迟=${rtt}ms(可信度=${NET[rtt_trust]:-})

  # BDP
  local bdp
  bdp="$(two_bdp_bytes "$bw" "$rtt")"
  local bdp_mib
  bdp_mib="$(two_round_up_mib "$bdp")"
  REC[bdp_bytes]="$bdp"
  REC[bdp_mib]="$bdp_mib"
  REC_NOTES+=("BDP = ${bw}Mbps(来源:${NET[bandwidth_source]:-}) × ${rtt}ms(延迟可信度:${NET[rtt_trust]:-}) × 1000 ÷ 8 = ${bdp} 字节 ≈ ${bdp_mib}MiB（仅作链路满速参考，非最终缓冲区）${speed_ref}")

  # 内存预算
  local mem_total_mb="${HW[mem_total_mb_int]:-0}"
  local mem_avail_mb="${HW[mem_avail_mb]:-0}"
  two_is_uint "$mem_total_mb" || mem_total_mb=0
  two_is_uint "$mem_avail_mb" || mem_avail_mb=0
  # 可用内存缺失时保守用总量的一半
  if (( mem_avail_mb == 0 )); then
    mem_avail_mb=$(( mem_total_mb / 2 ))
    REC_NOTES+=("MemAvailable 缺失，保守按总量 50% 估算可用内存=${mem_avail_mb}MB")
  fi
  REC[mem_avail_mb]="$mem_avail_mb"
  REC[mem_total_mb]="$mem_total_mb"

  # ---- 选基础档位（§6.3，按内存为主，结合带宽/RTT）----
  local tier base_fraction base_concurrency
  if (( mem_total_mb <= 1024 )); then
    tier="A"; base_fraction=0.20; base_concurrency=32
  elif (( mem_total_mb <= 4096 )); then
    tier="B"; base_fraction=0.30; base_concurrency=16
  else
    tier="C"; base_fraction=0.50; base_concurrency=8
  fi

  # 高 RTT + 高带宽场景：若内存充足，B 档可上探 C 档特性
  if [[ "$tier" == "B" ]] && (( bdp_mib > 8 )) && (( mem_avail_mb > 2048 )); then
    REC_NOTES+=("检测到高带宽·高RTT(BDP=${bdp_mib}MiB)，在内存充足下按 C 档预算计算上限")
    tier="C"; base_fraction=0.50; base_concurrency=8
  fi

  local fraction="$base_fraction" concurrency="$base_concurrency"

  # ---- 内存预算约束（追加强调 §3：缓冲区必须受内存限制，考虑并发）----
  # 预算 = 可用内存 × 占比（占比即"愿意让 TCP 缓冲区在极端情况下最多吃掉多少内存"）
  local budget_bytes
  budget_bytes="$(awk -v a="$mem_avail_mb" -v f="$fraction" 'BEGIN{printf "%d", a*1024*1024*f}')"
  local afford_bytes
  afford_bytes=$(( budget_bytes / concurrency ))
  (( afford_bytes <= 0 )) && afford_bytes=4194304   # 保底 4MiB，避免算出 0
  local afford_mib
  afford_mib="$(two_round_up_mib "$afford_bytes")"
  REC[mem_budget_mb]="$(( budget_bytes / 1048576 ))"
  REC[concurrency]="$concurrency"
  REC[afford_mib]="$afford_mib"
  REC_NOTES+=("内存预算 = 可用${mem_avail_mb}MB × ${fraction} / 假设${concurrency}并发 ≈ 单连接可分配上限 ${afford_mib}MiB")

  # ---- 推荐 max = min(BDP, 内存可分配上限)，再 1MiB 对齐 ----
  local max_mib
  if (( bdp_mib <= afford_mib )); then
    max_mib="$bdp_mib"
    REC[downgraded]="no"
  else
    max_mib="$afford_mib"
    REC[downgraded]="yes"
    REC_NOTES+=("⚠ BDP(${bdp_mib}MiB) 超过内存预算可分配上限(${afford_mib}MiB)，出于稳定性将缓冲区上限压至 ${max_mib}MiB（稳定性优先）")
  fi

  # ---- 档位降级判定：若被迫大幅压 BDP（<50%），降级显示档位 ----
  local final_tier="$tier"
  if [[ "${REC[downgraded]:-}" == "yes" ]] && (( bdp_mib > 0 && afford_mib * 2 < bdp_mib )); then
    case "$tier" in
      C) final_tier="B";;
      B) final_tier="A";;
      *) final_tier="A";;
    esac
    REC_NOTES+=("⚠ 内存压力较大：推荐档位由 ${tier} 降级为 ${final_tier}（稳定优先）")
  fi

  REC[tier]="$final_tier"
  case "$final_tier" in
    A) REC[tier_name]="稳定优先";;
    B) REC[tier_name]="均衡优化";;
    C) REC[tier_name]="高吞吐优化";;
  esac

  # ---- 生成 rmem / wmem 三元组 (min default max) ----
  # 接收(rmem)略大于发送(wmem)：接收侧要消化突发，更关键
  local rmin=4096
  local rmax_bytes=$(( max_mib * 1048576 ))
  # default = BDP 的 1/4 起（on-demand 会按需增长到 max），但不低于 min、不高于 max
  local rdef_bytes
  rdef_bytes=$(( bdp / 4 ))
  (( rdef_bytes < 4096 )) && rdef_bytes=4096
  (( rdef_bytes > rmax_bytes )) && rdef_bytes="$rmax_bytes"
  # 把 default 对齐到 64KiB 倍数（整齐值）
  rdef_bytes=$(( (rdef_bytes + 65535) / 65536 * 65536 ))
  (( rdef_bytes < rmin )) && rdef_bytes="$rmin"
  (( rdef_bytes > rmax_bytes )) && rdef_bytes="$rmax_bytes"

  REC[rmem]="${rmin} ${rdef_bytes} ${rmax_bytes}"

  # 发送(wmem)：max 取接收的 3/4（发送不需要那么大），min 保持
  local wmax_bytes=$(( rmax_bytes * 3 / 4 ))
  (( wmax_bytes < rmin )) && wmax_bytes="$rmin"
  local wdef_bytes=$(( rdef_bytes * 3 / 4 ))
  (( wdef_bytes < rmin )) && wdef_bytes="$rmin"
  REC[wmem]="${rmin} ${wdef_bytes} ${wmax_bytes}"

  # 全局缓冲区上限（net.core.rmem_max / wmem_max）
  # 这些是"硬上限"，需 ≥ 上述 rmem/wmem max；设为 max 本身（on-demand 才真正占用）
  REC[rmem_max]="$rmax_bytes"
  REC[wmem_max]="$wmax_bytes"

  # 其他建议（只在"确实影响且当前非默认"时给，避免盲目改）
  REC[moderate_rcvbuf]="$({ [[ "${SYS[param_ok.net.ipv4.tcp_moderate_rcvbuf]:-}" == "1" ]] && echo 1 || echo ""; })"
  REC[window_scaling]=1

  # 汇总说明（结构化提示：直接显示测得的参考值，非从报告读）
  printf '推荐计算: 实测带宽=%sMbps 实测延迟=%sms BDP=%s字节 档位=%s 降级=%s\n' \
    "${NET[bandwidth_mbps]:-未测}" \
    "${NET[rtt_ms]:-未测}" \
    "${REC[bdp_bytes]:-无}" \
    "${REC[tier]:-无}" \
    "${REC[downgraded]:-无}"
  REC_NOTES+=("最终推荐：rmem=${REC[rmem]} / wmem=${REC[wmem]} / rmem_max=${REC[rmem_max]} / wmem_max=${REC[wmem_max]} (字节)")
  REC_NOTES+=("档位=${final_tier}(${REC[tier_name]})，缓冲区按需分配，max 为上限非预留")
  return 0
}
