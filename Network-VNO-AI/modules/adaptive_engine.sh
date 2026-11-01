#!/bin/bash
# Network-VNO-AI 阶段 3：智能自适应计算引擎（adaptive_engine.sh）
# 任务书第 10/11/12 章：多因素输入 → BDP → 内存预算 → 参数推荐 → 三档决策 → 业务场景 → 数据置信度
# 规则：纯 Bash + awk；核心零 Python；读取实测数据真实计算（绝不写死常量）；需求1(已合理则不建议改)/需求2(能力确认才推荐BBR)。
# 所有路径走 common.sh。本模块只计算并写建议，绝不修改系统。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tcp_optimizer.sh"

MODULE_NAME="智能自适应计算引擎"
OUTPUT_FILE="${DATA_DIR}/recommendations.json"

# 读取配置/数据辅助
read_num() { local v; v=$(get_json_number "$1" "$2"); echo "${v:-0}"; }
read_str() { local v; v=$(get_json_field "$1" "$2"); echo "${v:-}"; }

# 按业务场景估算并发连接数（用于内存预算）
profile_concurrency() {
    case "$1" in
        website) echo 256 ;; high_concurrent) echo 4096 ;; high_bandwidth) echo 512 ;;
        proxy_tunnel) echo 1024 ;; low_latency) echo 1024 ;; high_rtt_cross_region) echo 1024 ;;
        *) echo 512 ;;
    esac
}

main() {
    local profile="${1:-default}"
    echo "=== $MODULE_NAME ==="
    echo "正在读取实测数据并真实计算优化建议（只读，不修改系统）..."

    # ---------- 输入参数 ----------
    local mem_total mem_avail cpu_steal if_virtual
    mem_total=$(read_num "${DATA_DIR}/hardware.json" mem_total_mb)
    mem_avail=$(read_num "${DATA_DIR}/hardware.json" mem_available_mb)
    cpu_steal=$(read_str "${DATA_DIR}/hardware.json" cpu_steal_percent)
    if_virtual=$(read_str "${DATA_DIR}/hardware.json" is_virtual)

    # 有效带宽：实测 > 用户配置 > 保守默认（任务书：数据不足时保守，不虚构）
    local bw=100 bw_src="保守默认(100Mbps)" trust="low"
    if [[ -r "${DATA_DIR}/bandwidth.json" ]]; then
        local m; m=$(read_str "${DATA_DIR}/bandwidth.json" download_mbps)
        if [[ "$m" =~ ^[0-9.]+$ ]]; then bw="$m"; bw_src="实测带宽(${m}Mbps)"; trust="high"; fi
    fi
    if [[ "$trust" != "high" ]]; then
        local ub="${VNO_BANDWIDTH_MBPS:-}"
        [[ -z "$ub" && -r "${CONFIG_DIR}/network.conf" ]] && ub=$(awk -F= '/user_bandwidth_mbps/{gsub(/[ \t]/,"",$2);print $2}' "${CONFIG_DIR}/network.conf")
        if [[ "$ub" =~ ^[0-9.]+$ ]]; then bw="$ub"; bw_src="用户配置(${ub}Mbps)"; trust="medium"; fi
    fi

    # 有效 RTT：优先 p95，其次 avg；未知则保守默认 20ms（信任度降为 low）
    local rtt=20 rtt_src="保守默认(20ms)"
    if [[ -r "${DATA_DIR}/network_quality.json" ]]; then
        local p avg; p=$(read_str "${DATA_DIR}/network_quality.json" p95_ms); avg=$(read_str "${DATA_DIR}/network_quality.json" avg_ms)
        if [[ "$p" =~ ^[0-9.]+$ ]]; then rtt="$p"; rtt_src="实测p95(${p}ms)"; [[ "$trust" == "low" ]] && trust="medium"; fi
        [[ "$rtt" == "20" && "$avg" =~ ^[0-9.]+$ ]] && { rtt="$avg"; rtt_src="实测avg(${avg}ms)"; }
    fi
    # RTT 未实测（保守默认）→ 即使带宽已测，整体信任度也不应标 high
    [[ "$rtt_src" == "保守默认(20ms)" && "$trust" == "high" ]] && trust="medium"

    # 并发估算
    local conns; conns=$(profile_concurrency "$profile")

    # ---------- 调用真实计算（来自 tcp_optimizer 库）----------
    compute_tcp_params "$bw" "$rtt" "$mem_avail" "$mem_total" "$conns"
    local bdp="$BDP_BYTES"

    # 当前内核值（用于差异对比与"已合理"判定）
    local cur_rmem_max cur_wmem_max cur_rmem_def cur_wmem_def cur_mod cur_ws cur_cc cur_cc_avail cur_qdisc
    cur_rmem_max=$(read_num "${DATA_DIR}/tcp_detect_result.json" tcp_rmem_max)
    cur_wmem_max=$(read_num "${DATA_DIR}/tcp_detect_result.json" tcp_wmem_max)
    cur_rmem_def=$(read_num "${DATA_DIR}/tcp_detect_result.json" tcp_rmem_default)
    cur_wmem_def=$(read_num "${DATA_DIR}/tcp_detect_result.json" tcp_wmem_default)
    cur_mod=$(read_str "${DATA_DIR}/tcp_detect_result.json" tcp_moderate_rcvbuf)
    cur_ws=$(read_str "${DATA_DIR}/tcp_detect_result.json" tcp_window_scaling)
    cur_cc=$(read_str "${DATA_DIR}/tcp_detect_result.json" current_algorithm)
    cur_cc_avail=$(read_str "${DATA_DIR}/tcp_detect_result.json" available_algorithms)
    cur_qdisc=$(read_str "${DATA_DIR}/tcp_detect_result.json" default_qdisc)

    # ---------- 需求1：已合理则不建议修改 ----------
    local already_optimal="false" opt_reason=""
    # 判定：当前 rmem_max 已不小于 1.5×BDP、moderate_rcvbuf=1、window_scaling=1、内存充足、RTT 较低、无异常
    local bdp_floor; bdp_floor=$(awk "BEGIN{printf \"%.0f\", $bdp*1.5}")
    case "$cpu_steal" in [5-9].*|[1-9][0-9]*) steal_high=1 ;; *) steal_high=0 ;; esac
    [[ "$cur_rmem_max" -ge "$bdp_floor" ]] 2>/dev/null && rmem_ok=1 || rmem_ok=0
    [[ "$cur_mod" == "1" && "$cur_ws" == "1" && "${mem_total:-0}" -ge 2048 && "$(awk "BEGIN{print ($rtt<30)?1:0}")" == "1" && "$steal_high" == "0" && "$rmem_ok" == "1" ]] && {
        already_optimal="true"
        opt_reason="当前缓冲区(${cur_rmem_max}B)已≥1.5×BDP(${bdp_floor}B)，且窗口缩放/自动调节已开启、内存充足、延迟较低、无异常。参数已合理，不建议修改（保持现状即成功交付）。"
    }

    # ---------- 三档决策（12 章：按实际条件，不只看内存）----------
    local level="$TCP_LEVEL_HINT"
    if [[ "$already_optimal" == "true" ]]; then
        level="无需修改（当前已合理）"
    else
        if [[ "${mem_total:-0}" -lt 2048 ]]; then level="Level 1（稳定优化）"
        elif [[ "${mem_total:-0}" -lt 8192 ]]; then level="Level 2（均衡优化）"
        else
            # 8GB+ 且高带宽/高RTT/已实测才升 L3，否则保守 L2
            if awk "BEGIN{exit !( $bw>=500 && $rtt>=30 )}"; then level="Level 3（高性能优化，需实测验证）"
            else level="Level 2（均衡优化）"; fi
        fi
    fi

    # ---------- 需求2：拥塞控制能力门控推荐 ----------
    local cc_rec="$cur_cc" cc_reason="保持当前 ${cur_cc:-未知}"
    if [[ "$already_optimal" != "true" ]]; then
        if echo "$cur_cc_avail" | grep -q "bbr"; then
            # BBR 是否真可用：受限虚拟化环境谨慎；非受限且大内存/高RTT才推荐
            local restricted=0
            echo "$if_virtual" | grep -qiE "虚拟化|容器" && restricted=1
            if [[ "$restricted" -eq 0 ]] && awk "BEGIN{exit !( $rtt>=30 || $bw>=500 )}"; then
                cc_rec="bbr"; cc_reason="当前环境非受限虚拟化且(高RTT或高带宽)，BBR 已实际注册，可在验证后切换以发挥长肥管道优势；切换前会单独确认。"
            else
                cc_reason="BBR 虽已注册，但当前为受限虚拟化/低延迟/低带宽场景，CUBIC 更稳妥，保持当前 ${cur_cc}。"
            fi
        else
            cc_reason="内核未注册 BBR（available 列表无 bbr），不强制升级内核；保持当前 ${cur_cc}（CUBIC 类默认最稳）。"
        fi
    fi

    # ---------- 队列(qdisc)能力门控推荐（6.2）----------
    local qdisc_rec="$cur_qdisc" qdisc_reason="保持当前 ${cur_qdisc:-未知}"
    if [[ "$already_optimal" != "true" ]]; then
        # 仅根据场景给出建议；实际切换需用户确认且备份现有规则
        case "$profile" in
            low_latency) qdisc_rec="fq_codel"; qdisc_reason="低延迟场景建议 fq_codel 控制排队延迟（需内核/模块支持且备份现有 tc 规则后应用）。" ;;
            high_bandwidth|high_rtt_cross_region) qdisc_rec="fq"; qdisc_reason="大带宽/高RTT场景建议 fq（公平排队+pacing），配合 BBR 更佳（需 NIC 支持且备份后应用）。" ;;
            *) qdisc_reason="通用场景保持当前 ${cur_qdisc:-未知}；如需可评估 fq_codel。" ;;
        esac
    fi

    # ---------- 各参数推荐明细（10.4）----------
    # 已在 compute_tcp_params 计算结果；此处组装 current/rec/basis/risk/suggest
    local rmem_max_rec="$TCP_RMEM_MAX" wmem_max_rec="$TCP_WMEM_MAX" \
          rmem_def_rec="$TCP_RMEM_DEFAULT" wmem_def_rec="$TCP_WMEM_DEFAULT"
    local bdp_human; bdp_human=$(awk "BEGIN{printf \"%.2f\", $bdp/1024/1024}")
    local basis="BDP=${bdp_human}MiB（带宽${bw}Mbps×RTT${rtt}ms）；每连接预算=$((PER_CONN_BUDGET/1024))KB；rmem_max=min(2×BDP, 每连接预算, 内存硬上限)，下限64KB。"
    local rmem_suggest="true" wmem_suggest="true"
    [[ "$already_optimal" == "true" ]] && { rmem_suggest="false"; wmem_suggest="false"; }
    [[ "$rmem_max_rec" == "$cur_rmem_max" ]] && rmem_suggest="false"
    [[ "$wmem_max_rec" == "$cur_wmem_max" ]] && wmem_suggest="false"
    local risk_note="修改过大可能抬升内存压力；过小限制吞吐。本方案已按可用内存与并发上限封顶，安全。"

    # ---------- 输出 ----------
    echo "计算完成："
    vno_log INFO "有效带宽=${bw}Mbps（来源：${bw_src}）；有效RTT=${rtt}ms（来源：${rtt_src}）；预估并发=${conns}"
    vno_log INFO "BDP≈${bdp_human}MiB；每连接预算=$((PER_CONN_BUDGET/1024))KB"
    vno_log INFO "推荐 tcp_rmem max=${rmem_max_rec}($((rmem_max_rec/1024))KB) / tcp_wmem max=${wmem_max_rec}($((wmem_max_rec/1024))KB)"
    vno_log INFO "拥塞控制：${cc_rec}（${cc_reason}）"
    vno_log INFO "队列(qdisc)：${qdisc_rec}（${qdisc_reason}）"
    vno_log INFO "优化档位：${level}；已合理=${already_optimal}；信任度=${trust}"
    [[ "$already_optimal" == "true" ]] && vno_log INFO "结论：${opt_reason}"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"adaptive_engine\","
      echo "  \"stage\": 3,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"calculation_input\": {"
      echo "    \"profile\": \"$(sanitize_json "$profile")\","
      echo "    \"effective_bandwidth_mbps\": ${bw},"
      echo "    \"bandwidth_source\": \"$(sanitize_json "$bw_src")\","
      echo "    \"effective_rtt_ms\": ${rtt},"
      echo "    \"rtt_source\": \"$(sanitize_json "$rtt_src")\","
      echo "    \"mem_total_mb\": ${mem_total:-0},"
      echo "    \"mem_available_mb\": ${mem_avail:-0},"
      echo "    \"estimated_concurrency\": ${conns},"
      echo "    \"cpu_steal_percent\": \"$(sanitize_json "$cpu_steal")\","
      echo "    \"is_virtual\": \"$(sanitize_json "$if_virtual")\""
      echo "  },"
      echo "  \"bdp\": {"
      echo "    \"bdp_bytes\": ${bdp},"
      echo "    \"bdp_mib\": ${bdp_human},"
      echo "    \"formula\": \"BDP(Bytes)=带宽(Mbps)×RTT(ms)×1000/8\","
      echo "    \"note\": \"BDP 仅作链路满速参考，不直接设为缓冲区上限\""
      echo "  },"
      echo "  \"memory_budget\": {"
      echo "    \"per_connection_budget_bytes\": ${PER_CONN_BUDGET},"
      echo "    \"per_connection_budget_kb\": $((PER_CONN_BUDGET/1024)),"
      echo "    \"rule\": \"缓冲区预算=可用内存×分级系数÷预估并发；不把最大缓冲当作每条连接固定分配\""
      echo "  },"
      echo "  \"optimization_recommendation\": {"
      echo "    \"recommended_level\": \"$(sanitize_json "$level")\","
      echo "    \"already_optimal\": ${already_optimal},"
      echo "    \"already_optimal_reason\": \"$(sanitize_json "$opt_reason")\","
      echo "    \"confidence\": \"$(sanitize_json "$trust")\""
      echo "  },"
      echo "  \"parameter_recommendations\": {"
      echo "    \"tcp_rmem\": {"
      echo "      \"current_max\": ${cur_rmem_max:-0}, \"recommended_min\": ${TCP_RMEM_MIN}, \"recommended_default\": ${TCP_RMEM_DEFAULT}, \"recommended_max\": ${TCP_RMEM_MAX},"
      echo "      \"basis\": \"$(sanitize_json "$basis")\", \"condition\": \"中等内存环境可考虑均衡优化\", \"risk\": \"$(sanitize_json "$risk_note")\", \"suggest_modify\": ${rmem_suggest}"
      echo "    },"
      echo "    \"tcp_wmem\": {"
      echo "      \"current_max\": ${cur_wmem_max:-0}, \"recommended_min\": ${TCP_WMEM_MIN}, \"recommended_default\": ${TCP_WMEM_DEFAULT}, \"recommended_max\": ${TCP_WMEM_MAX},"
      echo "      \"basis\": \"$(sanitize_json "$basis")\", \"condition\": \"结合写入负载\", \"risk\": \"$(sanitize_json "$risk_note")\", \"suggest_modify\": ${wmem_suggest}"
      echo "    },"
      echo "    \"net.core.rmem_max\": { \"current\": ${cur_rmem_max:-0}, \"recommended\": ${CORE_RMEM_MAX}, \"suggest_modify\": ${rmem_suggest} },"
      echo "    \"net.core.wmem_max\": { \"current\": ${cur_wmem_max:-0}, \"recommended\": ${CORE_WMEM_MAX}, \"suggest_modify\": ${wmem_suggest} },"
      echo "    \"net.core.rmem_default\": { \"recommended\": ${CORE_RMEM_DEFAULT} },"
      echo "    \"net.core.wmem_default\": { \"recommended\": ${CORE_WMEM_DEFAULT} },"
      echo "    \"net.ipv4.tcp_moderate_rcvbuf\": { \"recommended\": 1, \"note\": \"保持自动窗口调节开启\" },"
      echo "    \"net.ipv4.tcp_window_scaling\": { \"recommended\": 1, \"note\": \"保持窗口缩放开启\" }"
      echo "  },"
      echo "  \"congestion_recommendation\": {"
      echo "    \"current\": \"$(sanitize_json "$cur_cc")\", \"recommended\": \"$(sanitize_json "$cc_rec")\", \"reason\": \"$(sanitize_json "$cc_reason")\", \"require_confirm\": true"
      echo "  },"
      echo "  \"qdisc_recommendation\": {"
      echo "    \"current\": \"$(sanitize_json "$cur_qdisc")\", \"recommended\": \"$(sanitize_json "$qdisc_rec")\", \"reason\": \"$(sanitize_json "$qdisc_reason")\", \"require_confirm\": true"
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"智能计算完成，未修改系统；建议数据已保存到 recommendations.json，应用需经 safe_config 在用户确认后执行\""
      echo "}"
    } > "$OUTPUT_FILE"

    echo "已保存优化建议到 ${OUTPUT_FILE}"

    # 导出 shell 变量文件（供 safe_config 直接 source，零 Python 依赖；与 JSON 同源同算）
    cat > "${DATA_DIR}/recommendations.sh" << EOF
# 由 adaptive_engine 生成，供 safe_config 读取（请勿手改）
REC_TCP_RMEM_MIN=${TCP_RMEM_MIN}
REC_TCP_RMEM_DEFAULT=${TCP_RMEM_DEFAULT}
REC_TCP_RMEM_MAX=${TCP_RMEM_MAX}
REC_TCP_WMEM_MIN=${TCP_WMEM_MIN}
REC_TCP_WMEM_DEFAULT=${TCP_WMEM_DEFAULT}
REC_TCP_WMEM_MAX=${TCP_WMEM_MAX}
REC_CORE_RMEM_MAX=${CORE_RMEM_MAX}
REC_CORE_WMEM_MAX=${CORE_WMEM_MAX}
REC_CORE_RMEM_DEFAULT=${CORE_RMEM_DEFAULT}
REC_CORE_WMEM_DEFAULT=${CORE_WMEM_DEFAULT}
REC_MODERATE_RCVBUF=1
REC_WINDOW_SCALING=1
REC_CC="${cc_rec}"
REC_CC_CONFIRM=true
REC_QDISC="${qdisc_rec}"
REC_LEVEL="${level}"
REC_ALREADY_OPTIMAL=${already_optimal}
REC_SUGGEST_RMEM=${rmem_suggest}
REC_SUGGEST_WMEM=${wmem_suggest}
REC_CONFIDENCE="${trust}"
EOF

    echo "阶段 3 模块 adaptive_engine 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
