#!/bin/bash
# Network-VNO-AI 高级诊断：带宽实测（bandwidth_test.sh）
# 任务书第 8 章（可信测速：HTTP 多流/用户指定/iperf3）。
# 用户要求：默认允许测速，但测速前必须明示「预计流量与时长」。本模块默认直接执行（先打印估计，再测量），
#           可用 --dry-run 只看估计不下载；可用 --url 指定测试文件；可用 --time 控制单轮上限(秒)。
# 规则：纯 Bash；依赖探测；失败不崩溃；统一 JSON 到 data/bandwidth.json。路径走 common.sh。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="带宽实测"
JSON_FILE="${DATA_DIR}/bandwidth.json"

# 默认测试文件（可被 config/network.conf 的 bandwidth_test_url 或 --url 覆盖）
DEFAULT_URL="https://speed.cloudflare.com/__down?bytes=25000000"

# 读取默认 URL（如有配置）
cfg_url=""
[[ -r "${CONFIG_DIR}/network.conf" ]] && cfg_url="$(read_conf_value "${CONFIG_DIR}/network.conf" network bandwidth_test_url 2>/dev/null)"
DEFAULT_URL="${cfg_url:-$DEFAULT_URL}"

measure_http() {
    local url="$1" max_time="$2"
    [[ -z "$(have_cmd curl && echo x)" ]] && { echo "0 0 0"; return; }
    local start end bytes speed
    start=$(date +%s.%N 2>/dev/null || echo 0)
    bytes=$(curl -s -o /dev/null -w "%{size_download}" --max-time "$max_time" "$url" 2>/dev/null)
    end=$(date +%s.%N 2>/dev/null || echo 0)
    [[ -z "$bytes" || "$bytes" == "0" ]] && { echo "0 0 0"; return; }
    local dur; dur=$(awk "BEGIN{ d=$end-$start; if(d<=0) d=1; printf \"%.3f\", d }")
    speed=$(awk "BEGIN{ printf \"%.0f\", ($bytes/$dur)*8 }")   # bps
    local mbps; mbps=$(awk "BEGIN{ printf \"%.2f\", $speed/1000000 }")
    echo "$mbps $bytes $dur"
}

main() {
    local dry_run=0 url="$DEFAULT_URL" max_time=10 do_upload=0 yes=0
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --url) shift; url="$1" ;;
            --time) shift; max_time="$1" ;;
            --upload) do_upload=1 ;;
            --yes|-y) yes=1 ;;
        esac
        shift || true
    done
    [[ "${VNO_YES:-0}" == "1" ]] && yes=1

    echo "=== $MODULE_NAME ==="

    # 预计流量与时长（用户要求：测速前必须明示）
    local est_size_mb="约 25"
    local est_time="约 ${max_time} 秒（单轮上限）"
    vno_log INFO "测速方式：HTTP 下载采样（curl，最长为 ${max_time}s），真实产生下载流量"
    vno_log INFO "预计流量：${est_size_mb} MB 以内（受 --time 上限约束，不会无限下载）"
    vno_log INFO "预计时长：${est_time}；对象：${url}"
    [[ "$do_upload" == "1" ]] && vno_log INFO "将额外进行上传测试（需指定可写目标，默认跳过）"
    [[ "$dry_run" == "1" ]] && { vno_log INFO "（dry-run：仅显示估计，不实际下载）"; return 0; }

    # 默认允许测速：直接执行（已明示估计）
    local res; res="$(measure_http "$url" "$max_time")"
    local dl_mbps dl_bytes dl_dur
    read -r dl_mbps dl_bytes dl_dur <<< "$res"
    if [[ -z "$dl_mbps" || "$dl_mbps" == "0" || "$dl_mbps" == "0.00" ]]; then
        vno_log WARN "下载测速未获取到有效数据（可能无外网或目标不可达），不虚构带宽数值"
        dl_mbps="未测得"; dl_bytes=0; dl_dur=0
    else
        vno_log INFO "实测下载带宽≈${dl_mbps} Mbps（下载 ${dl_bytes} 字节，用时 ${dl_dur}s）"
    fi

    local up_mbps="未测试"
    if [[ "$do_upload" == "1" && -n "${VNO_UPLOAD_URL:-}" ]]; then
        if [[ -n "$(have_cmd curl && echo x)" ]]; then
            local us; us=$(curl -s -o /dev/null -w "%{size_upload}" -T /dev/null --max-time "$max_time" "${VNO_UPLOAD_URL}" 2>/dev/null)
            [[ -n "$us" && "$us" != "0" ]] && up_mbps=$(awk "BEGIN{ printf \"%.2f\", ($us/$dl_dur)*8/1000000 }")
        fi
    fi

    # iperf3（若可用且提供服务器）
    local iperf_note="未启用"
    if [[ -n "${VNO_IPERF_SERVER:-}" && -n "$(have_cmd iperf3 && echo x)" ]]; then
        local ir; ir=$(iperf3 -c "${VNO_IPERF_SERVER}" -t "$max_time" -J 2>/dev/null | grep -oE '"bps": [0-9]+' | head -1 | awk '{print $2}')
        [[ -n "$ir" ]] && { dl_mbps=$(awk "BEGIN{printf \"%.2f\", $ir/1000000}"); iperf_note="已用 iperf3 到 ${VNO_IPERF_SERVER}"; }
    fi

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"bandwidth_test\","
      echo "  \"stage\": 6,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"download_mbps\": \"$(sanitize_json "$dl_mbps")\","
      echo "  \"upload_mbps\": \"$(sanitize_json "$up_mbps")\","
      echo "  \"bytes_transferred\": ${dl_bytes:-0},"
      echo "  \"duration_s\": \"$(sanitize_json "$dl_dur")\","
      echo "  \"test_target\": \"$(sanitize_json "$url")\","
      echo "  \"method\": \"http_curl_sampled\","
      echo "  \"iperf_note\": \"$(sanitize_json "$iperf_note")\","
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"带宽实测完成（默认允许测速，已先明示流量与时长）；无外网时不虚构数值\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存带宽数据到 ${JSON_FILE}"
    echo "阶段 6 模块 bandwidth_test 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
