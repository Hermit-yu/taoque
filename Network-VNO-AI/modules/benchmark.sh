#!/bin/bash
# Network-VNO-AI 性能基准闭环（benchmark.sh）
# 任务书第 13/15 章：优化闭环 = ① 基准 → ② 诊断计算 → ③ 安全应用 → ④ 复测 → ⑤ 评价
# 核心竞争力：不只给建议，而是用真实前后测量验证「优化是否真的带来收益」，无收益则建议保留现状/回滚。
# 规则：纯 Bash；依赖探测；失败不崩溃；默认只读式测量；应用由 safe_config 在用户确认后执行。路径走 common.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tcp_optimizer.sh"

MODULE_NAME="性能基准闭环"
MOD_DIR="$(dirname "${BASH_SOURCE[0]}")"

# 采集一次快照（聚合「网络测量」+「当前真实生效的调优参数」两层数据）
# 网络层来自各检测模块的真实测量；参数层用 read_sysctl 直接读 /proc/sys 当前生效值，
# 不依赖检测模块 JSON —— 这样基准/复测两次快照对比的，是机器调优前后的真实状态。
# 若 safe_config 写入后未真正 sysctl 重载，参数层不会变，评价会如实反映「参数未生效」。
capture_snapshot() {
    local out="$1"
    ensure_dirs
    # 网络层：来自各检测模块真实测量
    local rtt_avg rtt_p95 loss bw rmem wmem retrans estab tw
    rtt_avg="$(get_json_field "${DATA_DIR}/network_quality.json" avg_ms)"
    rtt_p95="$(get_json_field "${DATA_DIR}/network_quality.json" p95_ms)"
    loss="$(get_json_field "${DATA_DIR}/network_quality.json" packet_loss_pct)"
    bw="$(get_json_field "${DATA_DIR}/bandwidth.json" download_mbps)"
    rmem="$(get_json_number "${DATA_DIR}/tcp_detect_result.json" tcp_rmem_max)"
    wmem="$(get_json_number "${DATA_DIR}/tcp_detect_result.json" tcp_wmem_max)"
    retrans="$(get_json_number "${DATA_DIR}/tcp_detect_result.json" retrans_segs)"
    estab="$(get_json_number "${DATA_DIR}/tcp_detect_result.json" established)"
    tw="$(get_json_number "${DATA_DIR}/tcp_detect_result.json" time_wait)"

    # 参数层：直接读当前真实生效的调优参数（/proc/sys，不依赖检测模块 JSON）
    local ap_rmem ap_wmem ap_cc ap_ws ap_mr ap_crmem ap_cwmem ap_dq
    ap_rmem="$(read_sysctl net.ipv4.tcp_rmem)";   ap_rmem="${ap_rmem##* }"   # tcp_rmem 为 3 元组，取 max
    ap_wmem="$(read_sysctl net.ipv4.tcp_wmem)";   ap_wmem="${ap_wmem##* }"
    ap_cc="$(read_sysctl net.ipv4.tcp_congestion_control)"
    ap_ws="$(read_sysctl net.ipv4.tcp_window_scaling)"
    ap_mr="$(read_sysctl net.ipv4.tcp_moderate_rcvbuf)"
    ap_crmem="$(read_sysctl net.core.rmem_max)"
    ap_cwmem="$(read_sysctl net.core.wmem_max)"
    ap_dq="$(read_sysctl net.core.default_qdisc)"
    [[ -z "$ap_rmem"  ]] && ap_rmem="未测得"
    [[ -z "$ap_wmem"  ]] && ap_wmem="未测得"
    [[ -z "$ap_cc"    ]] && ap_cc="未测得"
    [[ -z "$ap_ws"    ]] && ap_ws="未测得"
    [[ -z "$ap_mr"    ]] && ap_mr="未测得"
    [[ -z "$ap_crmem" ]] && ap_crmem="未测得"
    [[ -z "$ap_cwmem" ]] && ap_cwmem="未测得"
    [[ -z "$ap_dq"    ]] && ap_dq="未测得"

    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"benchmark_snapshot\","
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"rtt_avg_ms\": \"${rtt_avg:-未测得}\","
      echo "  \"rtt_p95_ms\": \"${rtt_p95:-未测得}\","
      echo "  \"packet_loss_pct\": \"${loss:-未测得}\","
      echo "  \"download_mbps\": \"${bw:-未测得}\","
      echo "  \"tcp_rmem_max\": ${rmem:-0},"
      echo "  \"tcp_wmem_max\": ${wmem:-0},"
      echo "  \"tcp_retrans_segs\": ${retrans:-0},"
      echo "  \"tcp_established\": ${estab:-0},"
      echo "  \"tcp_time_wait\": ${tw:-0},"
      echo "  \"ap_tcp_rmem_max\": \"${ap_rmem}\","
      echo "  \"ap_tcp_wmem_max\": \"${ap_wmem}\","
      echo "  \"ap_tcp_congestion_control\": \"${ap_cc}\","
      echo "  \"ap_tcp_window_scaling\": \"${ap_ws}\","
      echo "  \"ap_tcp_moderate_rcvbuf\": \"${ap_mr}\","
      echo "  \"ap_core_rmem_max\": \"${ap_crmem}\","
      echo "  \"ap_core_wmem_max\": \"${ap_cwmem}\","
      echo "  \"ap_default_qdisc\": \"${ap_dq}\""
      echo "}"
    } > "$out"
    echo "已保存快照到 $out"
}

num() { local v="$1"; v="${v//[^0-9.]/}"; echo "${v:-0}"; }

evaluate() {
    local b="${DATA_DIR}/benchmark_baseline.json" a="${DATA_DIR}/benchmark_after.json"
    [[ -r "$b" && -r "$a" ]] || { echo "缺少基准或复测数据，先运行 --baseline 与 --post。"; return 1; }

    # 网络层（基础值）
    local b_rtt b_bw b_re a_rtt a_bw a_re
    b_rtt="$(num "$(get_json_field "$b" rtt_avg_ms)")"
    a_rtt="$(num "$(get_json_field "$a" rtt_avg_ms)")"
    b_bw="$(num "$(get_json_field "$b" download_mbps)")"
    a_bw="$(num "$(get_json_field "$a" download_mbps)")"
    b_re="$(get_json_number "$b" tcp_retrans_segs)"
    a_re="$(get_json_number "$a" tcp_retrans_segs)"

    local rtt_delta bw_delta re_delta
    rtt_delta=$(awk "BEGIN{printf \"%.2f\", $a_rtt-$b_rtt}")
    bw_delta=$(awk "BEGIN{printf \"%.2f\", $a_bw-$b_bw}")
    re_delta=$(( a_re - b_re ))

    # 数据可用性：RTT 与带宽两端都必须有有效数值，否则无法归因（不假装「不显著」）
    local data_sufficient="true"
    if [[ $(awk "BEGIN{print ($b_rtt>0 && $a_rtt>0)?1:0}") -eq 0 && $(awk "BEGIN{print ($b_bw>0 && $a_bw>0)?1:0}") -eq 0 ]]; then
        data_sufficient="false"
    fi

    # 参数层：对比基准/复测两套「当前真实生效参数」，确认脚本调优是否真的改变了系统
    local param_diffs="" pcount=0 pk bv av
    for pk in ap_tcp_rmem_max ap_tcp_wmem_max ap_tcp_congestion_control ap_tcp_window_scaling ap_tcp_moderate_rcvbuf ap_core_rmem_max ap_core_wmem_max ap_default_qdisc; do
        bv="$(get_json_field "$b" "$pk")"
        av="$(get_json_field "$a" "$pk")"
        [[ "$bv" != "$av" ]] && { param_diffs="${param_diffs} ${pk#ap_}:${bv}->${av}"; pcount=$((pcount+1)); }
    done
    local params_changed="否"; [[ $pcount -gt 0 ]] && params_changed="是"

    # 网络层判定（阈值：RTT↓5% / 带宽↑5% 视为改善；RTT↑10% / 带宽↓10% 视为退化）
    # 网络层逐项真实变化描述（方向 + 幅度 + 具体数值），供结论与判定共用
    local rtt_desc="未测得" bw_desc="未测得" re_desc="未测得"
    [[ $(awk "BEGIN{print ($b_rtt>0 && $a_rtt>0)?1:0}") -eq 1 ]] && \
        rtt_desc=$(awk "BEGIN{d=$a_rtt-$b_rtt; p=($b_rtt>0)?(d/$b_rtt*100):0; if(d<-1e-9)s=\"改善\"; else if(d>1e-9)s=\"退化\"; else s=\"持平\"; printf \"RTT %.2f→%.2fms (%+.1f%%, %s)\", $b_rtt, $a_rtt, p, s}")
    [[ $(awk "BEGIN{print ($b_bw>0 && $a_bw>0)?1:0}") -eq 1 ]] && \
        bw_desc=$(awk "BEGIN{d=$a_bw-$b_bw; p=($b_bw>0)?(d/$b_bw*100):0; if(d>1e-9)s=\"改善\"; else if(d<-1e-9)s=\"退化\"; else s=\"持平\"; printf \"带宽 %.2f→%.2fMbps (%+.1f%%, %s)\", $b_bw, $a_bw, p, s}")
    [[ $(awk "BEGIN{print ($b_re>0 || $a_re>0)?1:0}") -eq 1 ]] && \
        re_desc=$(awk "BEGIN{d=$a_re-$b_re; if(d<0)s=\"改善\"; else if(d>0)s=\"退化\"; else s=\"持平\"; printf \"重传 %d→%d 段 (%s)\", $b_re, $a_re, s}")

    # 把测得且有意义的网络变化拼成一句自然描述（用空格连接，去前导空格）
    local net_parts=""
    [[ "$rtt_desc" != "未测得" ]] && net_parts="${net_parts} ${rtt_desc}"
    [[ "$bw_desc" != "未测得" ]] && net_parts="${net_parts} ${bw_desc}"
    [[ "$re_desc" != "未测得" ]] && net_parts="${net_parts} ${re_desc}"
    net_parts="${net_parts# }"
    [[ -z "$net_parts" ]] && net_parts="无测得指标"

    local improved=0 degraded=0
    awk "BEGIN{ if($b_rtt>0 && $a_rtt>0 && $a_rtt < $b_rtt*0.95) c=1; else c=0; exit !c }" && improved=$((improved+1))
    awk "BEGIN{ if($b_bw>0 && $a_bw>0 && $a_bw > $b_bw*1.05) c=1; else c=0; exit !c }" && improved=$((improved+1))
    awk "BEGIN{ if($a_re < $b_re) c=1; else c=0; exit !c }" && improved=$((improved+1))
    awk "BEGIN{ if($b_rtt>0 && $a_rtt>0 && $a_rtt > $b_rtt*1.10) c=1; else c=0; exit !c }" && degraded=$((degraded+1))
    awk "BEGIN{ if($b_bw>0 && $a_bw>0 && $a_bw < $b_bw*0.90) c=1; else c=0; exit !c }" && degraded=$((degraded+1))

    # 结论：严格基于「参数层是否真变」+「网络层真实变化」生成，不预设，且描述含具体实测数值与方向
    local verdict note pdiff_note=""
    [[ "$params_changed" == "是" ]] && pdiff_note="（生效参数变化：${param_diffs}）"
    if [[ "$data_sufficient" == "false" ]]; then
        verdict="数据不足：基准或复测缺少有效的 RTT/带宽测量，无法评价调优效果。请确认 network_quality 与 bandwidth_test 已成功采集后再评。"
    else
        if [[ $improved -gt 0 && $degraded -eq 0 ]]; then
            if [[ "$params_changed" == "是" ]]; then
                verdict="优化有效${pdiff_note}；网络层实测：${net_parts}；至少一项改善且无明显退化，建议保留当前配置。"
            else
                verdict="网络指标改善但生效参数未变化（参数层无差异）；实测：${net_parts}；改善可能源于网络自身波动或调优未真正生效；建议确认 safe_config --apply 是否成功执行并 sysctl 已重载。"
            fi
        elif [[ $degraded -gt 0 && $improved -eq 0 ]]; then
            if [[ "$params_changed" == "是" ]]; then
                verdict="未观察到收益且出现退化${pdiff_note}；网络层实测：${net_parts}；建议回滚（safe_config --rollback）。"
            else
                verdict="出现退化但生效参数未变化；网络层实测：${net_parts}；退化与脚本调优无关，应源于网络自身；如持续变差请排查线路。"
            fi
        else
            if [[ "$params_changed" == "是" ]]; then
                verdict="参数已变化${pdiff_note}但网络指标变化不显著；网络层实测：${net_parts}；建议多轮复测后再判定，暂不承诺收益。"
            else
                verdict="生效参数未变化且网络指标变化不显著；网络层实测：${net_parts}；可能未实际应用调优；建议确认 --apply 是否执行后再评。"
            fi
        fi
    fi
    note="评价完全基于本机调优前后（基准快照 vs 复测快照）的真实测量与生效参数对比，结论描述含具体实测数值与方向（RTT/带宽/重传 各维度真实变化），不含任何预设措辞；单次测量受网络波动影响，需多轮验证。"

    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"benchmark_evaluation\","
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"basis\": \"调优前后真实测量对比（baseline vs after）\","
      echo "  \"rtt_delta\": ${rtt_delta},"
      echo "  \"bandwidth_delta\": ${bw_delta},"
      echo "  \"retrans_delta\": ${re_delta},"
      echo "  \"improved_dims\": ${improved},"
      echo "  \"degraded_dims\": ${degraded},"
      echo "  \"params_changed\": \"${params_changed}\","
      echo "  \"param_diffs\": \"$(sanitize_json "$param_diffs")\","
      echo "  \"net_summary\": \"$(sanitize_json "$net_parts")\","
      echo "  \"data_sufficient\": ${data_sufficient},"
      echo "  \"verdict\": \"$(sanitize_json "$verdict")\","
      echo "  \"note\": \"$(sanitize_json "$note")\""
      echo "}"
    } > "${DATA_DIR}/benchmark_evaluation.json"
    echo "评价结果：${verdict}"
    echo "RTT 变化=${rtt_delta}ms，带宽变化=${bw_delta}Mbps，重传变化=${re_delta}，参数变化=${params_changed}"
}

usage() {
    cat <<EOF
用法：benchmark.sh [--baseline|--post|--evaluate|--full|--report]
  --baseline  采集优化前基准（需先运行 network_quality / bandwidth_test / tcp_detect）
  --post      采集优化后复测快照
  --evaluate  对比基准与复测，生成评价（benchmark_evaluation.json）
  --full      基准 → 自适应计算 → 安全应用(需确认) → 复测 → 评价（完整闭环）
  --report    仅打印最近一次评价
EOF
}

main() {
    local cmd="${1:---report}"
    echo "=== $MODULE_NAME ==="
    case "$cmd" in
        --baseline)
            bash "$MOD_DIR/network_quality.sh" >/dev/null 2>&1
            bash "$MOD_DIR/bandwidth_test.sh" --yes >/dev/null 2>&1
            bash "$MOD_DIR/tcp_detect.sh" >/dev/null 2>&1
            capture_snapshot "${DATA_DIR}/benchmark_baseline.json"
            echo "阶段① 基准采集完成。" ;;
        --post)
            bash "$MOD_DIR/network_quality.sh" >/dev/null 2>&1
            bash "$MOD_DIR/bandwidth_test.sh" --yes >/dev/null 2>&1
            bash "$MOD_DIR/tcp_detect.sh" >/dev/null 2>&1
            capture_snapshot "${DATA_DIR}/benchmark_after.json"
            echo "阶段④ 复测采集完成。" ;;
        --evaluate) evaluate ;;
        --full)
            echo "① 基准采集..."; bash "$0" --baseline
            echo "② 智能诊断与参数计算..."; bash "$MOD_DIR/adaptive_engine.sh" >/dev/null 2>&1
            echo "③ 安全应用（将请求确认）..."; bash "$MOD_DIR/safe_config.sh" --apply || echo "应用未执行或已取消"
            echo "④ 复测采集..."; bash "$0" --post
            echo "⑤ 生成评价..."; evaluate ;;
        --report)
            if [[ -r "${DATA_DIR}/benchmark_evaluation.json" ]]; then
                python3 -c "import json;print(json.load(open('${DATA_DIR}/benchmark_evaluation.json'))['verdict'])" 2>/dev/null || cat "${DATA_DIR}/benchmark_evaluation.json"
            else echo "尚无评价数据，请先运行 --baseline / --post / --evaluate。"; fi ;;
        *) usage ;;
    esac
    echo "阶段 benchmark 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
