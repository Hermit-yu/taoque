#!/bin/bash
# Network-VNO-AI 高级诊断：Bufferbloat 检测（bufferbloat_test.sh）
# 任务书第 8 章（空闲/下载/上传/双向 RTT 增量检测）。
# 规则：纯 Bash；依赖探测；失败不崩溃；默认只读式负载（会发起短期下载制造负载，但流量受 --time 约束）；
#       统一 JSON 到 data/bufferbloat.json。路径走 common.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="Bufferbloat 检测"
JSON_FILE="${DATA_DIR}/bufferbloat.json"

# 测空闲 RTT：返回 "avg mdev loss"
ping_avg() {
    local target="$1" count="${2:-10}"
    [[ -z "$(have_cmd ping && echo x)" ]] && { echo "0 0 0"; return; }
    local raw; raw=$(ping -c "$count" -W 2 "$target" 2>/dev/null) || { echo "0 0 0"; return; }
    local avg loss
    avg=$(echo "$raw" | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+ ms' | head -1 | sed -E 's#([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms#\2#')
    loss=$(echo "$raw" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+' | head -1)
    [[ -z "$loss" ]] && loss=0
    echo "${avg:-0} 0 ${loss:-0}"
}

default_gw_or_pub() {
    [[ -n "$(have_cmd ip && echo x)" ]] && { ip route show default 2>/dev/null | awk '{print $3; exit}'; }
    echo "1.1.1.1"
}

main() {
    local max_time=15 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --time) shift; max_time="$1" ;;
        esac
        shift || true
    done

    echo "=== $MODULE_NAME ==="
    local target; target="$(default_gw_or_pub)"
    vno_log INFO "检测目标=${target}；将通过短期下载制造负载并对比 RTT 增量"
    vno_log INFO "预计流量：受 ${max_time}s 下载上限约束，不会无限下载"
    [[ "$dry_run" == "1" ]] && { vno_log INFO "（dry-run：仅说明，不制造负载）"; return 0; }

    # 空闲基线
    local idle; idle="$(ping_avg "$target" 10)"
    local idle_avg idle_loss; read -r idle_avg _ idle_loss <<< "$idle"
    vno_log INFO "空闲 RTT 平均=${idle_avg}ms，丢包=${idle_loss}%"

    # 制造下载负载并同时测 RTT
    local load_avg="0" load_loss="0"
    if [[ -n "$(have_cmd curl && echo x)" ]]; then
        vno_log INFO "正在制造下载负载（${max_time}s）并测量负载下 RTT..."
        # 后台下载（限速不太现实，直接拉取大文件到 /dev/null）
        ( curl -s -o /dev/null --max-time "$max_time" "https://speed.cloudflare.com/__down?bytes=200000000" >/dev/null 2>&1 ) &
        local dlpid=$!
        local load; load="$(ping_avg "$target" "$max_time")"
        wait "$dlpid" 2>/dev/null
        read -r load_avg _ load_loss <<< "$load"
        vno_log INFO "负载下 RTT 平均=${load_avg}ms，丢包=${load_loss}%"
    else
        vno_log WARN "无 curl，无法制造负载，跳过负载测量"
    fi

    # 增量与判定
    local delta="0" verdict="无法判定"
    if [[ "$idle_avg" != "0" && "$load_avg" != "0" ]]; then
        delta=$(awk "BEGIN{printf \"%.1f\", $load_avg-$idle_avg}")
        local pct; pct=$(awk "BEGIN{ if($idle_avg>0) printf \"%.0f\", ($load_avg-$idle_avg)/$idle_avg*100; else print 0 }")
        if awk "BEGIN{exit !($delta>30 || $pct>50)}"; then
            verdict="检测到明显 Bufferbloat（负载下 RTT 增加 ${delta}ms / ${pct}%，建议启用 fq_codel/cake 等 AQM）"
        else
            verdict="未检测到明显 Bufferbloat（负载下 RTT 增加 ${delta}ms / ${pct}%，在可接受范围）"
        fi
    fi
    vno_log INFO "${verdict}"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"bufferbloat_test\","
      echo "  \"stage\": 6,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"target\": \"$(sanitize_json "$target")\","
      echo "  \"idle\": { \"avg_rtt_ms\": \"${idle_avg}\", \"packet_loss_pct\": \"${idle_loss}\" },"
      echo "  \"under_load\": { \"avg_rtt_ms\": \"${load_avg}\", \"packet_loss_pct\": \"${load_loss}\" },"
      echo "  \"delta_ms\": \"${delta}\","
      echo "  \"verdict\": \"$(sanitize_json "$verdict")\","
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"Bufferbloat 检测完成；负载制造受 --time 上限约束\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存 Bufferbloat 数据到 ${JSON_FILE}"
    echo "阶段 6 模块 bufferbloat_test 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
