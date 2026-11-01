#!/bin/bash
# Network-VNO-AI 状态面板（status_panel.sh）
# 职责：把"哪些功能可用 / 哪些已检测到数据 / 优化是否真的应用到系统 / 有没有漂移"
#       实时、真实地汇总成用户一眼能看懂的面板。绝不写死结论，全部来自现场读取。
# 只读：不修改系统；读 /proc/sys、90-vno-ai.conf、data/*.json。路径走 common.sh（可重定向便于测试）。
# 用法：
#   bash status_panel.sh            完整面板
#   bash status_panel.sh --compact  单行速览（菜单启动时用）

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

COMPACT="${1:-}"
MOD_DIR="$(dirname "${BASH_SOURCE[0]}")"

# ---------- 小工具 ----------
# 文件是否"较新"（默认 24 小时内生成算"最新"）
fresh() {
    local f="$1" max_age="${2:-86400}" now mtime
    [[ -f "$f" ]] || { echo 0; return; }
    now="$(date +%s)"
    mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [[ -n "$mtime" ]] || mtime=0
    if [[ "$(( now - mtime ))" -le "$max_age" ]]; then echo 1; else echo 0; fi
}

# 读 90-vno-ai.conf 里某 key 的目标值（已应用配置里写的期望值）
conf_target() {
    local key="$1"
    [[ -r "$CONF_FILE" ]] || { echo ""; return; }
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONF_FILE" 2>/dev/null | sed -E 's/.*=[[:space:]]*//' | head -1
}

# 归一化 sysctl 值：制表符/多空格统一为单空格并去首尾空白
# （tcp_rmem/tcp_wmem 是多值，/proc 与 conf 的分隔符可能不同，必须先归一化再比）
_norm_val() { printf '%s' "$1" | tr '\t' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'; }

# 某项是否"已应用到系统"：conf 目标值 非空 且 与 /proc/sys 真实生效值一致
# 返回 1=已生效  2=已写入但未生效(漂移/未重载)  0=未写入该项
apply_state() {
    local key="$1" target actual
    target="$(_norm_val "$(conf_target "$key")")"
    [[ -z "$target" ]] && { echo 0; return; }
    actual="$(_norm_val "$(read_sysctl "$key")")"
    [[ -z "$actual" ]] && { echo 2; return; }
    [[ "$target" == "$actual" ]] && echo 1 || echo 2
}

# 图标
ICON_APPLIED="✓ 已生效"
ICON_DRIFT="⚠ 已写入未生效"
ICON_NONE="○ 未应用"
ICON_RUN="· 未检测"

# ---------- 维度一：检测功能可用性（模块脚本是否存在 → 真实可用）----------
declare -A MOD_NAME=(
    [system_detect]=硬件检测 [tcp_detect]=TCP深度诊断 [congestion_control]=拥塞控制
    [qdisc_manager]=队列诊断 [nic_optimizer]=网卡调优 [mtu_mss]=MTU/MSS
    [network_quality]=网络质量 [bandwidth_test]=带宽实测 [bufferbloat_test]=Bufferbloat
    [adaptive_engine]=自适应计算 [safe_config]=应用/回滚 [benchmark]=性能闭环
    [report_engine]=报告 [monitor]=长期监控
)
declare -A MOD_JSON=(
    [system_detect]=hardware.json [tcp_detect]=tcp_detect_result.json
    [congestion_control]=congestion_control.json [qdisc_manager]=qdisc.json
    [nic_optimizer]=nic.json [mtu_mss]=mtu_mss.json
    [network_quality]=network_quality.json [bandwidth_test]=bandwidth.json
    [bufferbloat_test]=bufferbloat.json
)

# ---------- compact 单行速览 ----------
if [[ "$COMPACT" == "--compact" ]]; then
    conf_present="否"
    [[ -r "$CONF_FILE" ]] && conf_present="是"
    avail=0; total=0
    for k in "${!MOD_NAME[@]}"; do total=$((total+1)); [[ -f "${MOD_DIR}/$k.sh" ]] && avail=$((avail+1)); done
    echo "【状态速览】模块可用 ${avail}/${total} ｜ 配置文件 ${conf_present} ｜ $(vno_now)"
    exit 0
fi

# ---------- 完整面板 ----------
echo ""
echo "╔══════════════════════ Network-VNO-AI 实际应用状态 ══════════════════════╗"
echo "生成时间：$(vno_now)"
echo "配置文件：${CONF_FILE}"
if [[ -r "$CONF_FILE" ]]; then
    echo "配置状态：✓ 已生成（本工具写入的独立 sysctl 配置）"
else
    echo "配置状态：○ 尚未生成（还没运行过 [12] 应用优化）"
fi
echo "╠══════════════════════ 一、核心调优是否真的应用到系统 ═══════════════════════"
echo "   状态         参数                   配置值 → 系统实际值"
# 逐项：仅当 conf 里写了该项才判定（没写 = 未应用该项，避免误报漂移）
k=""; target=""; actual=""; st=""; key=""; tag=""
declare -a CORE_KEYS=(net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max net.ipv4.tcp_congestion_control)
for k in "${CORE_KEYS[@]}"; do
    target="$(conf_target "$k")"
    actual="$(read_sysctl "$k" 2>/dev/null)"
    # 归一化空白（tcp_rmem/tcp_wmem 是多值，/proc 里可能带制表符）
    actual="$(printf '%s' "$actual" | tr '\t' ' ' | tr -s ' ')"
    target="$(printf '%s' "$target" | tr '\t' ' ' | tr -s ' ')"
    st="$(apply_state "$k")"
    key="${k##*.}"
    case "$st" in
        1) tag="✓ 已生效" ;;
        2) tag="⚠ 未生效" ;;
        *) tag="○ 未应用" ;;
    esac
    if [[ "$st" -eq 0 ]]; then
        printf "   %s %-22s 配置未含该项 ｜ 实际=%s\n" "$tag" "$key" "${actual:-未知}"
    else
        printf "   %s %-22s %s → %s\n" "$tag" "$key" "${target:-未知}" "${actual:-未知}"
    fi
done
echo "   （✓ 已生效=配置与系统实际一致；⚠ 未生效=已写入配置但系统尚未重载，可 sysctl -p；○ 未应用=配置未含该项）"

echo "╠══════════════════════ 二、各检测功能可用性 & 数据新鲜度 ═══════════════════"
echo "   模块          模块脚本                数据        功能"
avail_cnt=0; total_cnt=0
for k in system_detect tcp_detect congestion_control qdisc_manager nic_optimizer mtu_mss network_quality bandwidth_test bufferbloat_test adaptive_engine safe_config benchmark report_engine monitor; do
    total_cnt=$((total_cnt+1))
    mt="✗ 缺失"; ds="○ 未跑"; jf=""
    [[ -f "${MOD_DIR}/$k.sh" ]] && { mt="✓ 可用"; avail_cnt=$((avail_cnt+1)); }
    if [[ -n "${MOD_JSON[$k]:-}" ]]; then
        jf="${DATA_DIR}/${MOD_JSON[$k]}"
        if [[ -f "$jf" ]]; then
            if [[ "$(fresh "$jf")" -eq 1 ]]; then ds="✓ 新鲜"; else ds="⌛ 过时"; fi
        fi
    fi
    printf "   %s %-22s %s %s\n" "$mt" "$k" "$ds" "${MOD_NAME[$k]}"
done
echo "   （模块可用 ${avail_cnt}/${total_cnt}；数据：✓新鲜=24h 内生成 / ⌛过时=有数据但较旧 / ○未跑=还没执行过）"

echo "╠══════════════════════ 三、建议与备份 ═══════════════════════════════════"
rec_avail="无"; rec_level=""; rec_conf=""; rec_opt=""
if [[ -r "${DATA_DIR}/recommendations.sh" ]]; then
    [[ "$(fresh "${DATA_DIR}/recommendations.sh")" -eq 1 ]] && rec_avail="✓ 可用（新鲜）" || rec_avail="✓ 可用（较旧）"
    # 子 shell 内 source 拿等级/置信度/是否已合理（只读变量，不改系统）
    _rs="$(cd "$VNO_HOME" && source "${DATA_DIR}/recommendations.sh" 2>/dev/null; printf '%s|%s|%s' "${REC_LEVEL:-?}" "${REC_CONFIDENCE:-?}" "${REC_ALREADY_OPTIMAL:-?}")"
    IFS='|' read -r rec_level rec_conf rec_opt <<< "$_rs"
fi
if [[ "$rec_avail" == ✓* ]]; then
    echo "   优化建议：${rec_avail} ｜ 档位=${rec_level} 置信度=${rec_conf} 已合理=${rec_opt}"
else
    echo "   优化建议：○ 未生成（先运行 [11] 自适应计算）"
fi
bk_cnt=0
if [[ -d "$BACKUP_DIR" ]]; then bk_cnt="$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"; fi
if [[ "${bk_cnt:-0}" -gt 0 ]]; then
    echo "   备份快照：✓ ${bk_cnt} 个（可 [13] 回滚到备份）"
else
    echo "   备份快照：○ 暂无（应用优化前会自动生成）"
fi
echo "╚═══════════════════════════════════════════════════════════════════════╝"

# ---------- 面向用户的行动建议（基于实际状态，不预设）----------
echo ""
echo "─── 下一步建议（根据当前实际状态给出）───"
acted=0
if [[ ! -r "$CONF_FILE" ]]; then
    echo "  • 尚未应用任何优化。若要调优：先 [11] 生成建议 → [12] 应用 → 再回来看本面板确认「已生效」。"; acted=1
fi
# 若存在已写入但未生效项，提示重载
drift_keys=()
for k in "${CORE_KEYS[@]}"; do
    [[ -n "$(conf_target "$k")" ]] || continue
    [[ "$(apply_state "$k")" -eq 2 ]] && drift_keys+=("$k")
done
if [[ ${#drift_keys[@]} -gt 0 ]]; then
    echo "  • 检测到 ${#drift_keys[@]} 项已写入配置但未在系统中生效：${drift_keys[*]}; 可执行 [12] 应用（含 sysctl 重载）或手动 sysctl -p ${CONF_FILE}。"; acted=1
fi
if [[ "$(fresh "${DATA_DIR}/tcp_detect_result.json" 2>/dev/null)" -ne 1 ]]; then
    echo "  • TCP 检测数据缺失或已过时，建议先跑 [3] 或 [1] 完整检测，让面板数据反映真实网络。"; acted=1
fi
if [[ $acted -eq 0 ]]; then
    echo "  • 一切正常：配置已生成、核心项已生效、检测数据新鲜。如需复测收益可跑 [14] 性能闭环。"
fi

exit 0
