#!/bin/bash
# Network-VNO-AI 阶段 3：TCP 缓冲区计算库（tcp_optimizer.sh）
# 任务书第 10.2/10.3/10.4：BDP 计算 + 多因素内存预算 + 参数推荐（真实数学，可单测）
# 设计：本文件既是可被 adaptive_engine source 的计算库，也可独立运行（从实测数据或实时内核读取后输出建议）。
# 规则：纯 Bash + awk；核心零 Python 依赖；所有推荐值附计算依据，绝不臆造。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" 2>/dev/null || true

# ---------- 计算：TCP 缓冲区参数 ----------
# 调用：compute_tcp_params <bw_mbps> <rtt_ms> <mem_avail_mb> <mem_total_mb> <active_conns> [current_rmem_max] [current_wmem_max]
# 结果写入以下全局变量（便于单测断言）：
#   BDP_BYTES PER_CONN_BUDGET MEM_BUDGET_RAW TCP_RMEM_MIN TCP_RMEM_DEFAULT TCP_RMEM_MAX
#   TCP_WMEM_MIN TCP_WMEM_DEFAULT TCP_WMEM_MAX CORE_RMEM_MAX CORE_WMEM_MAX CORE_RMEM_DEFAULT CORE_WMEM_DEFAULT
#   TCP_LEVEL_HINT TCP_NOTES
compute_tcp_params() {
    local bw="$1" rtt="$2" mem_avail_mb="$3" mem_total_mb="$4" active_conns="${5:-1024}"
    local cur_rmem_max="${6:-0}" cur_wmem_max="${7:-0}"

    # 1) BDP（带宽时延积）
    local bdp
    bdp=$(awk "BEGIN{printf \"%.0f\", ($bw)*($rtt)*1000/8}")
    [[ "$bdp" -lt 1 ]] && bdp=1
    BDP_BYTES="$bdp"

    # 2) 多因素内存预算（10.3）：按总内存分级决定 TCP 可用比例，再除以预估并发连接
    local factor
    if [[ "${mem_total_mb}" -lt 512 ]]; then factor=10
    elif [[ "${mem_total_mb}" -lt 2048 ]]; then factor=20
    elif [[ "${mem_total_mb}" -lt 8192 ]]; then factor=30
    else factor=40; fi
    local avail_bytes=$(( mem_avail_mb * 1024 * 1024 ))
    local mem_budget=$(( avail_bytes * factor / 100 ))
    [[ "$mem_budget" -lt $((16*1024*1024)) ]] && mem_budget=$((16*1024*1024))
    local per_conn=$(( mem_budget / active_conns ))
    [[ "$per_conn" -lt 16384 ]] && per_conn=16384
    MEM_BUDGET_RAW="$mem_budget"
    PER_CONN_BUDGET="$per_conn"

    # 3) 硬上限（防止单一参数无上限放大）：随内存分级
    local hard_cap
    if [[ "${mem_total_mb}" -lt 512 ]]; then hard_cap=$((512*1024))
    elif [[ "${mem_total_mb}" -lt 2048 ]]; then hard_cap=$((2*1024*1024))
    elif [[ "${mem_total_mb}" -lt 8192 ]]; then hard_cap=$((4*1024*1024))
    else hard_cap=$((16*1024*1024)); fi

    # 4) rmem_max = min(2×BDP, 每连接预算, 硬上限)；下限 64KB（自动窗口调节需要空间）；按 4KB 对齐
    local rmem_max=$(( 2 * bdp ))
    [[ "$rmem_max" -gt "$per_conn" ]] && rmem_max="$per_conn"
    [[ "$rmem_max" -gt "$hard_cap" ]] && rmem_max="$hard_cap"
    [[ "$rmem_max" -lt 65536 ]] && rmem_max=65536
    rmem_max=$(( (rmem_max / 4096) * 4096 ))
    TCP_RMEM_MAX="$rmem_max"

    # rmem_default = min(BDP, rmem_max/2)，下限 16KB
    local rmem_def=$(( bdp ))
    [[ "$rmem_def" -gt $(( rmem_max / 2 )) ]] && rmem_def=$(( rmem_max / 2 ))
    [[ "$rmem_def" -lt 16384 ]] && rmem_def=16384
    rmem_def=$(( (rmem_def / 4096) * 4096 ))
    TCP_RMEM_DEFAULT="$rmem_def"
    TCP_RMEM_MIN=4096

    # 5) wmem（发送缓冲）：与接收同理，对称处理
    local wmem_max=$(( 2 * bdp ))
    [[ "$wmem_max" -gt "$per_conn" ]] && wmem_max="$per_conn"
    [[ "$wmem_max" -gt "$hard_cap" ]] && wmem_max="$hard_cap"
    [[ "$wmem_max" -lt 65536 ]] && wmem_max=65536
    wmem_max=$(( (wmem_max / 4096) * 4096 ))
    TCP_WMEM_MAX="$wmem_max"
    local wmem_def=$(( bdp ))
    [[ "$wmem_def" -gt $(( wmem_max / 2 )) ]] && wmem_def=$(( wmem_max / 2 ))
    [[ "$wmem_def" -lt 16384 ]] && wmem_def=16384
    wmem_def=$(( (wmem_def / 4096) * 4096 ))
    TCP_WMEM_DEFAULT="$wmem_def"
    TCP_WMEM_MIN=4096

    # 6) core.* 全局：等于我们为 TCP 调好的值（作为全局 socket 缓冲上限）
    CORE_RMEM_MAX="$rmem_max"; CORE_WMEM_MAX="$wmem_max"
    CORE_RMEM_DEFAULT="$rmem_def"; CORE_WMEM_DEFAULT="$wmem_def"

    # 7) 等级提示（内存为主；任务书 12 章：512MB-1GB=稳定，2-8GB=均衡，8GB+=高性能）
    local lvl
    if [[ "${mem_total_mb}" -lt 2048 ]]; then lvl="Level 1（稳定优化）"
    elif [[ "${mem_total_mb}" -lt 8192 ]]; then lvl="Level 2（均衡优化）"
    else lvl="Level 3（高性能优化，需实测验证）"; fi
    TCP_LEVEL_HINT="$lvl"

    TCP_NOTES="BDP=${bdp}B；每连接预算=$((per_conn/1024))KB；内存预算约占可用内存 ${factor}%；rmem_max 受(2×BDP,每连接预算,硬上限)三者中最小者约束"
    return 0
}

# 人类可读输出
print_tcp_params() {
    echo "  BDP 参考值：${BDP_BYTES} 字节"
    echo "  每连接预算：$((PER_CONN_BUDGET/1024)) KB；内存预算系数已计入"
    echo "  tcp_rmem（min/default/max）= ${TCP_RMEM_MIN} / ${TCP_RMEM_DEFAULT} / ${TCP_RMEM_MAX}"
    echo "  tcp_wmem（min/default/max）= ${TCP_WMEM_MIN} / ${TCP_WMEM_DEFAULT} / ${TCP_WMEM_MAX}"
    echo "  net.core.rmem_max/wmem_max = ${CORE_RMEM_MAX} / ${CORE_WMEM_MAX}"
    echo "  net.core.rmem_default/wmem_default = ${CORE_RMEM_DEFAULT} / ${CORE_WMEM_DEFAULT}"
    echo "  等级提示：${TCP_LEVEL_HINT}"
    echo "  依据：${TCP_NOTES}"
}

# 独立运行：从实测数据或实时内核读取后计算
main() {
    echo "=== TCP 缓冲区智能计算（tcp_optimizer）==="
    local bw=100 rtt=1 avail=1000 total=2000 conns=1024
    # 优先读取实测数据
    if [[ -r "${DATA_DIR}/bandwidth.json" ]]; then
        local m; m=$(get_json_field "${DATA_DIR}/bandwidth.json" "download_mbps")
        [[ "$m" =~ ^[0-9.]+$ ]] && bw="$m"
    elif [[ -r "${DATA_DIR}/hardware.json" ]]; then
        local ub; ub=$(get_json_field "${DATA_DIR}/hardware.json" "user_bandwidth_mbps")
        [[ "$ub" =~ ^[0-9.]+$ ]] && bw="$ub"
    fi
    [[ -r "${DATA_DIR}/network_quality.json" ]] && { local r; r=$(get_json_field "${DATA_DIR}/network_quality.json" "avg_ms"); [[ "$r" =~ ^[0-9.]+$ ]] && rtt="$r"; }
    [[ -r "${DATA_DIR}/hardware.json" ]] && {
        local a t; a=$(get_json_number "${DATA_DIR}/hardware.json" "mem_available_mb"); t=$(get_json_number "${DATA_DIR}/hardware.json" "mem_total_mb")
        [[ "$a" -gt 0 ]] && avail="$a"; [[ "$t" -gt 0 ]] && total="$t"
    }
    # 实时覆盖（有 sysctl 时）
    local cr; cr=$(read_sysctl net.ipv4.tcp_rmem | awk '{print $3}'); [[ "$cr" =~ ^[0-9]+$ ]] && cur_rmem="$cr" || cur_rmem=0
    local cw; cw=$(read_sysctl net.ipv4.tcp_wmem | awk '{print $3}'); [[ "$cw" =~ ^[0-9]+$ ]] && cur_wmem="$cw" || cur_wmem=0

    echo "输入：带宽≈${bw}Mbps，RTT≈${rtt}ms，可用内存≈${avail}MB，总内存≈${total}MB，预估并发≈${conns}"
    compute_tcp_params "$bw" "$rtt" "$avail" "$total" "$conns" "$cur_rmem" "$cur_wmem"
    print_tcp_params
    echo "（本模块仅计算并展示，不修改系统；应用由 safe_config 在用户确认后执行）"
}

# 被 source 时只提供函数；直接运行才执行 main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
