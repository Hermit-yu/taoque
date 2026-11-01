#!/bin/bash
# Network-VNO-AI 长期监控（monitor.sh）
# 任务书第 15 章：配置漂移检测、历史数据、重新计算建议。
# 规则：纯 Bash；默认只读；不修改系统、不自动应用；统一 JSON 到 data/monitor.json。路径走 common.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="长期监控"
JSON_FILE="${DATA_DIR}/monitor.json"
MOD_DIR="$(dirname "${BASH_SOURCE[0]}")"

# 读取已应用配置（90-vno-ai.conf）中的某个 sysctl 值
conf_value() {
    local key="$1" f="$CONF_FILE"
    [[ -r "$f" ]] || { echo ""; return; }
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null | sed -E 's/.*=[[:space:]]*//' | head -1
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在检测配置漂移与历史数据（只读，不修改系统）..."

    # 当前生效值（从 /proc 读，mock 友好）
    local cur_rmem cur_wmem cur_rmax cur_wmax cur_ws cur_mod cur_cc
    cur_rmem="$(read_sysctl net.ipv4.tcp_rmem)"
    cur_wmem="$(read_sysctl net.ipv4.tcp_wmem)"
    cur_rmax="$(read_sysctl net.core.rmem_max)"
    cur_wmax="$(read_sysctl net.core.wmem_max)"
    cur_ws="$(read_sysctl net.ipv4.tcp_window_scaling)"
    cur_mod="$(read_sysctl net.ipv4.tcp_moderate_rcvbuf)"
    cur_cc="$(read_sysctl net.ipv4.tcp_congestion_control)"

    # 已应用配置（若有）
    local applied_rmem applied_present="false"
    applied_rmem="$(conf_value 'net.ipv4.tcp_rmem')"
    [[ -n "$applied_rmem" ]] && applied_present="true"

    # 漂移判定：当前生效值 vs 已应用配置
    local drift="无"
    if [[ "$applied_present" == "true" ]]; then
        [[ "$(echo "$cur_rmem" | awk '{print $3}')" != "$(echo "$applied_rmem" | awk '{print $3}')" ]] && drift="检测到漂移（当前 tcp_rmem max 与已应用配置不一致，可能被人手改或重启后丢失）"
        [[ "$drift" == "无" && "$cur_cc" != "$(conf_value 'net.ipv4.tcp_congestion_control')" ]] && drift="检测到漂移（拥塞控制与已应用配置不一致）"
    else
        drift="未检测到本工具生成的配置文件（90-vno-ai.conf 不存在，可能尚未应用优化）"
    fi

    # 历史数据
    local hist_count=0 last_hist="无"
    if [[ -d "${HISTORY_DIR}" ]]; then
        hist_count="$(ls -1 "${HISTORY_DIR}" 2>/dev/null | wc -l | tr -d ' ')"
        last_hist="$(ls -1t "${HISTORY_DIR}" 2>/dev/null | head -1)"
        [[ -z "$last_hist" ]] && last_hist="无"
    fi

    # 重新计算建议并与已存推荐对比（判断环境是否变化导致建议变化）
    local rec_changed="未比较"
    if [[ -r "${DATA_DIR}/recommendations.json" ]]; then
        cp "${DATA_DIR}/recommendations.json" "${DATA_DIR}/recommendations.prev.json" 2>/dev/null || true
        bash "$MOD_DIR/adaptive_engine.sh" >/dev/null 2>&1
        if diff -q "${DATA_DIR}/recommendations.prev.json" "${DATA_DIR}/recommendations.json" >/dev/null 2>&1; then
            rec_changed="未变化（环境稳定，建议保持一致）"
        else
            rec_changed="建议已变化（检测到硬件/网络条件变化，重新计算的建议与上次不同，可复核后决定是否应用）"
        fi
        rm -f "${DATA_DIR}/recommendations.prev.json"
    else
        rec_changed="暂无历史建议可对比（请先运行自适应计算）"
    fi

    echo "监控结果："
    vno_log INFO "当前 tcp_rmem=${cur_rmem}；rmem_max=${cur_rmax}；拥塞控制=${cur_cc}"
    vno_log INFO "已应用配置存在=${applied_present}；漂移状态=${drift}"
    vno_log INFO "历史记录条数=${hist_count}；最近一条=${last_hist}"
    vno_log INFO "建议变化=${rec_changed}"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"monitor\","
      echo "  \"stage\": 15,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"current\": {"
      echo "    \"tcp_rmem\": \"$(sanitize_json "$cur_rmem")\","
      echo "    \"tcp_wmem\": \"$(sanitize_json "$cur_wmem")\","
      echo "    \"rmem_max\": \"${cur_rmax:-0}\","
      echo "    \"wmem_max\": \"${cur_wmax:-0}\","
      echo "    \"window_scaling\": \"$(sanitize_json "$cur_ws")\","
      echo "    \"moderate_rcvbuf\": \"$(sanitize_json "$cur_mod")\","
      echo "    \"congestion_control\": \"$(sanitize_json "$cur_cc")\""
      echo "  },"
      echo "  \"applied_config_present\": ${applied_present},"
      echo "  \"drift\": \"$(sanitize_json "$drift")\","
      echo "  \"history\": { \"count\": ${hist_count:-0}, \"latest\": \"$(sanitize_json "$last_hist")\" },"
      echo "  \"recommendation_change\": \"$(sanitize_json "$rec_changed")\","
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"监控完成，未修改系统；如需修正漂移，可重新运行 safe_config --apply（会再次备份）\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存监控数据到 ${JSON_FILE}"
    echo "阶段 15 模块 monitor 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
