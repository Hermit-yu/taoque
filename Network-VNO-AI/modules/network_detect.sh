#!/bin/bash
# Network-VNO-AI 网络检测编排 + 异常分析（network_detect.sh）
# 任务书第 8.4（网络异常分析）：结合硬件 steal、TCP 重传、网卡错误/丢包、高 TIME_WAIT 做综合判定。
# 说明：RTT 测量已交由 network_quality.sh（任务书 8.1）统一负责，本模块只做异常关联分析，写 data/network_analysis.json。
# 规则：纯 Bash；默认只读；不主动产生下载流量；统一 JSON 到 data/network_analysis.json。路径走 common.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="网络异常分析"
JSON_FILE="${DATA_DIR}/network_analysis.json"

main() {
    echo "=== $MODULE_NAME ==="

    # 先确保 RTT 数据存在（若 network_quality 尚未运行，则补跑）
    if [[ ! -r "${DATA_DIR}/network_quality.json" ]]; then
        echo "未找到 network_quality.json，先运行 network_quality.sh 测量 RTT..."
        bash "$(dirname "${BASH_SOURCE[0]}")/network_quality.sh" >/dev/null 2>&1 || true
    fi

    local best_loss best_avg
    best_loss=$(get_json_field "${DATA_DIR}/network_quality.json" packet_loss_pct)
    best_avg=$(get_json_field "${DATA_DIR}/network_quality.json" avg_ms)

    local anomalies=()
    [[ "$best_loss" != "未知" && "${best_loss:-0}" -gt 2 ]] 2>/dev/null && anomalies+=("RTT 丢包率 ${best_loss}%（>2%，可能存在链路丢包）")
    [[ -r "${DATA_DIR}/hardware.json" ]] && {
        local steal; steal=$(get_json_field "${DATA_DIR}/hardware.json" "cpu_steal_percent")
        case "$steal" in
            [5-9].*|[1-9][0-9]*) anomalies+=("CPU Steal ${steal}%（虚拟化资源争抢，可能影响网络处理）" ) ;;
        esac
    }
    [[ -r "${DATA_DIR}/tcp_detect_result.json" ]] && {
        local retrans tw; retrans=$(get_json_number "${DATA_DIR}/tcp_detect_result.json" "retrans_segs"); tw=$(get_json_number "${DATA_DIR}/tcp_detect_result.json" "time_wait")
        [[ "${retrans:-0}" -gt 1000 ]] && anomalies+=("TCP 重传 ${retrans}（偏高，可能存在链路质量问题）")
        [[ "${tw:-0}" -gt 10000 ]] && anomalies+=("TIME_WAIT ${tw}（偏高，需结合业务规模判断，不可直接认定异常）")
    }
    [[ -r "${DATA_DIR}/hardware.json" ]] && {
        local rxd txd; rxd=$(get_json_number "${DATA_DIR}/hardware.json" "rx_drop"); txd=$(get_json_number "${DATA_DIR}/hardware.json" "tx_drop")
        [[ "${rxd:-0}" -gt 0 || "${txd:-0}" -gt 0 ]] && anomalies+=("网卡丢包 RX=${rxd}/TX=${txd}（检查网卡或上行）")
    }
    [[ ${#anomalies[@]} -eq 0 ]] && anomalies+=("未检测到明显异常（数据有限，结论保守）")

    echo "网络异常分析完成："
    vno_log INFO "代表 RTT 平均=${best_avg}ms，丢包=${best_loss}%"
    vno_log INFO "异常项：${anomalies[*]}"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"network_detect_analysis\","
      echo "  \"stage\": 6,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"rtt_reference\": {"
      echo "    \"avg_ms\": \"${best_avg:-未知}\","
      echo "    \"packet_loss_pct\": \"${best_loss:-未知}\""
      echo "  },"
      echo "  \"anomaly_analysis\": ["
      local first=1
      for a in "${anomalies[@]}"; do
        if [[ $first -eq 1 ]]; then echo "    \"$(sanitize_json "$a")\""; first=0; else echo "    ,\"$(sanitize_json "$a")\""; fi
      done
      echo "  ],"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"网络异常分析完成，未修改系统配置；RTT 数据来自 network_quality.json\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存网络异常分析到 ${JSON_FILE}"
    echo "阶段 6 模块 network_detect (分析) 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
