#!/bin/bash
# Network-VNO-AI 阶段 5：安全配置管理（safe_config.sh）
# 任务书第 14 章：默认只读；应用前备份、显示差异、检查兼容性、请求确认、写独立配置、验证生效、可回滚；SSH/防火墙/网关保护。
# 复用 backup_manager.sh（do_backup）与 rollback_manager.sh（do_rollback）。
# 真实写参：依据 adaptive_engine 生成的 data/recommendations.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/backup_manager.sh"
source "$(dirname "${BASH_SOURCE[0]}")/rollback_manager.sh"

MODULE_NAME="安全配置管理"

# 构建推荐配置内容（输出到 stdout 的一行行 sysctl 配置）
build_config() {
    local rec="${DATA_DIR}/recommendations.sh"
    [[ -r "$rec" ]] || { echo "# 无推荐数据，请先运行 adaptive_engine" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$rec"
    echo "# Network-VNO-AI 自动生成配置（由 safe_config 应用）"
    echo "# 生成时间：$(vno_now)"
    echo "# 等级：${REC_LEVEL:-未知}；置信度：${REC_CONFIDENCE:-未知}；已合理=${REC_ALREADY_OPTIMAL}"
    echo "# 本文件使用独立 sysctl.d 配置，不覆盖 /etc/sysctl.conf，不修改 SSH/防火墙/网关"
    # 安全且有益的固定项
    echo "net.ipv4.tcp_moderate_rcvbuf = ${REC_MODERATE_RCVBUF}"
    echo "net.ipv4.tcp_window_scaling = ${REC_WINDOW_SCALING}"
    # 仅当建议修改时才写缓冲区参数（需求1：已合理则不改）
    if [[ "${REC_SUGGEST_RMEM}" == "true" ]]; then
        echo "net.ipv4.tcp_rmem = ${REC_TCP_RMEM_MIN} ${REC_TCP_RMEM_DEFAULT} ${REC_TCP_RMEM_MAX}"
    fi
    if [[ "${REC_SUGGEST_WMEM}" == "true" ]]; then
        echo "net.ipv4.tcp_wmem = ${REC_TCP_WMEM_MIN} ${REC_TCP_WMEM_DEFAULT} ${REC_TCP_WMEM_MAX}"
    fi
    if [[ "${REC_SUGGEST_RMEM}" == "true" || "${REC_SUGGEST_WMEM}" == "true" ]]; then
        echo "net.core.rmem_max = ${REC_CORE_RMEM_MAX}"
        echo "net.core.wmem_max = ${REC_CORE_WMEM_MAX}"
        echo "net.core.rmem_default = ${REC_CORE_RMEM_DEFAULT}"
        echo "net.core.wmem_default = ${REC_CORE_WMEM_DEFAULT}"
    fi
    # 拥塞控制为高风险管理项：默认不自动写入，需显式授权（--include-cc 或 VNO_INCLUDE_CC=1）
    if [[ "${VNO_INCLUDE_CC:-0}" == "1" ]]; then
        echo "net.ipv4.tcp_congestion_control = ${REC_CC}"
    fi
    return 0
}

# 写入配置到 CONF_FILE：先彻底擦除旧配置，再写入新内容（幂等，避免上次残留 key 遗留）
# 同时清理同目录下同名模式的旧版本配置文件，防止历史残留与新配置并存
write_config_file() {
    local content="$1"
    mkdir -p "$(dirname "$CONF_FILE")" 2>/dev/null
    # 1) 擦除目标文件自身（含符号链接，避免写到链接目标而留下本体）
    if [[ -e "$CONF_FILE" || -L "$CONF_FILE" ]]; then
        rm -f "$CONF_FILE" || { echo "  [注意] 擦除旧配置失败：$CONF_FILE" >&2; return 1; }
    fi
    # 2) 清理同目录下同名模式的旧版本配置（如 90-network-vno-ai.conf 等历史文件）
    local old
    for old in "$SYSCTL_DIR"/*vno-ai*.conf; do
        [[ -e "$old" && "$old" != "$CONF_FILE" ]] && rm -f "$old"
    done
    # 3) 写入新内容
    printf '%s\n' "$content" > "$CONF_FILE" || { echo "  [注意] 写入配置失败：$CONF_FILE" >&2; return 1; }
    echo "已擦除旧配置并写入新配置：${CONF_FILE}"
    return 0
}

# 验证实际生效值是否与推荐一致
verify_applied() {
    local rec="${DATA_DIR}/recommendations.sh"
    [[ -r "$rec" ]] || { echo "无推荐数据，跳过验证"; return; }
    # shellcheck disable=SC1090
    source "$rec"
    echo "=== 验证实际生效值 ==="
    local ok=0 bad=0
    local pairs=("net.ipv4.tcp_moderate_rcvbuf:${REC_MODERATE_RCVBUF}" "net.ipv4.tcp_window_scaling:${REC_WINDOW_SCALING}")
    if [[ "${REC_SUGGEST_RMEM}" == "true" ]]; then
        pairs+=("net.ipv4.tcp_rmem:${REC_TCP_RMEM_MIN} ${REC_TCP_RMEM_DEFAULT} ${REC_TCP_RMEM_MAX}")
        pairs+=("net.core.rmem_max:${REC_CORE_RMEM_MAX}")
    fi
    if [[ "${REC_SUGGEST_WMEM}" == "true" ]]; then
        pairs+=("net.ipv4.tcp_wmem:${REC_TCP_WMEM_MIN} ${REC_TCP_WMEM_DEFAULT} ${REC_TCP_WMEM_MAX}")
        pairs+=("net.core.wmem_max:${REC_CORE_WMEM_MAX}")
    fi
    for p in "${pairs[@]}"; do
        local k="${p%%:*}" v="${p#*:}"
        local actual; actual=$(read_sysctl "$k")
        if [[ "$actual" == "$v" ]]; then echo "  ✓ ${k} = ${actual}（一致）"; ok=$((ok+1))
        else echo "  ✗ ${k} 期望[${v}] 实际[${actual}]（可能需 sysctl -p 或重启网络栈）"; bad=$((bad+1)); fi
    done
    echo "验证结果：一致 ${ok} 项，不一致 ${bad} 项。"
    [[ "$bad" -eq 0 ]]
}

do_apply() {
    echo "=== 应用优化配置（安全流程）==="
    # 1) 权限检查
    if ! is_root; then
        echo "出错：修改系统配置需要 root 权限（当前非 root）。请使用 sudo 运行，或在受控环境中以 root 执行。" >&2
        return 1
    fi
    # 2) SSH 安全保护（任务书 14.5）
    if is_ssh_session; then
        echo "检测到通过 SSH 远程操作：本工具不修改 SSH 服务配置、不改默认网关、不改防火墙、不强制重启网络。"
    fi
    # 3) 前置兼容性检查
    if ! have_cmd sysctl; then
        echo "出错：未找到 sysctl 命令，无法应用。" >&2; return 1
    fi
    # 4) 备份
    local bdir; bdir=$(do_backup); echo "已备份原配置到：${bdir}"
    # 5) 生成配置
    local content; content=$(build_config) || return 1
    echo "--- 待写入配置（差异预览）---"
    echo "$content" | sed 's/^/  /'
    echo "--- 写入目标：${CONF_FILE} ---"
    # 6) 确认（交互 y/N；非交互需 VNO_YES=1 显式授权）
    local proceed=0
    if [[ -t 0 ]]; then
        read -r -p "确认应用以上配置？(y/N) " ans
        [[ "$ans" == "y" || "$ans" == "Y" ]] && proceed=1
    elif [[ "${VNO_YES:-0}" == "1" ]]; then
        proceed=1
    fi
    if [[ "$proceed" -ne 1 ]]; then
        echo "未确认，已取消应用（原系统未改动，备份保留）。"; return 0
    fi
    # 7) 写入独立文件（先彻底擦除旧配置，再写当前建议，保证幂等不残留）
    write_config_file "$content" || return 1
    # 8) 应用
    sysctl -p "$CONF_FILE" >/dev/null 2>&1 && echo "已通过 sysctl 应用。" || echo "sysctl 应用失败（配置已写入，可手动 sysctl -p ${CONF_FILE}）。"
    # 9) 验证
    verify_applied
    echo "应用完成。如需撤销：bash modules/safe_config.sh --rollback"
}

main() {
    case "${1:-}" in
        --backup) do_backup >/dev/null; echo "已执行备份。" ;;
        --rollback) do_rollback "${2:-}" ;;
        --apply) do_apply ;;
        --dry-run) echo "=== 配置预览（dry-run，不修改系统）==="; build_config ;;
        --verify) verify_applied ;;
        --help|"") echo "用法：bash safe_config.sh --backup | --rollback | --apply | --dry-run | --verify" ;;
        *) echo "未知参数：$1"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
