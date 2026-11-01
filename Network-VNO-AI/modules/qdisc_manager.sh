#!/bin/bash
# Network-VNO-AI 高级诊断：队列规则(qdisc)诊断（qdisc_manager.sh）
# 任务书第 6 章 + 需求 2（能力门控）
# 规则：纯 Bash；依赖逐项探测；失败不崩溃；默认只读；大白话；统一 JSON 到 data/qdisc.json。
# 路径走 common.sh（PROC_ROOT/SYS_ROOT 可重定向，便于测试）。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="队列规则(qdisc)诊断"
JSON_FILE="${DATA_DIR}/qdisc.json"

# 列出网络接口（优先 /sys/class/net，mock 友好）
list_ifaces() {
    if [[ -d "${SYS_ROOT}/class/net" ]]; then
        ls -1 "${SYS_ROOT}/class/net" 2>/dev/null | grep -v '^$' || true
    elif have_cmd ip; then
        ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' || true
    fi
}

# 检测某 qdisc 是否内核可用（模块或内置）
qdisc_supported() {
    local name="$1"
    [[ "$(read_sysctl net.core.default_qdisc 2>/dev/null)" == "$name" ]] && { echo "1"; return; }
    if have_cmd modprobe; then
        modprobe -n "sch_${name}" >/dev/null 2>&1 && echo "1" || echo "0"
    else
        echo "0"
    fi
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在检测各接口队列规则与内核支持（只读，不修改系统）..."

    local default_qdisc; default_qdisc="$(read_sysctl net.core.default_qdisc)"
    local ifaces; ifaces="$(list_ifaces)"

    # 逐接口采集 qdisc
    local iface_entries=""
    local primary_iface=""
    for ifc in $ifaces; do
        [[ "$ifc" == "lo" ]] && continue
        [[ -z "$primary_iface" ]] && primary_iface="$ifc"
        local q="未知"
        if have_cmd tc; then
            q="$(tc qdisc show dev "$ifc" 2>/dev/null | head -1)"
            [[ -z "$q" ]] && q="(无 tc 输出)"
        fi
        iface_entries="${iface_entries}    \"$ifc\": \"$(sanitize_json "$q")\","$'\n'
    done
    iface_entries="$(printf '%s' "$iface_entries" | sed '$ s/,$//')"
    [[ -z "$iface_entries" ]] && iface_entries="    \"(无可用接口)\": \"未知\""

    # 内核对各高级 qdisc 的支持度
    local fq sup_fq fqcodel sup_fqcodel cake sup_cake pfifo sup_pfifo
    fq="$(read_sysctl net.core.default_qdisc 2>/dev/null)"; sup_fq="$(qdisc_supported fq)"
    sup_fqcodel="$(qdisc_supported fq_codel)"
    sup_cake="$(qdisc_supported cake)"
    sup_pfifo="$(qdisc_supported pfifo_fast)"

    # 业务场景建议（需求 2：结合场景而非一味追新）
    local scene_rec="保持当前 ${default_qdisc:-未知}"
    local scene_reason=""
    # 读取自适应引擎的场景（如有），否则按通用处理
    local profile="default"
    if [[ -r "${DATA_DIR}/recommendations.json" ]]; then
        profile="$(get_json_field "${DATA_DIR}/recommendations.json" profile)"
        [[ "$profile" == "null" || -z "$profile" ]] && profile="default"
    fi
    case "$profile" in
        low_latency)
            scene_rec="fq_codel"
            scene_reason="低延迟场景建议 fq_codel（主动控制排队延迟，缓解 bufferbloat）；需内核支持且备份现有 tc 规则后应用。"
            [[ "$sup_fqcodel" == "0" ]] && scene_reason="${scene_reason}（当前内核未检测到 fq_codel 模块，需先确认支持）"
            ;;
        high_bandwidth|high_rtt_cross_region)
            scene_rec="fq"
            scene_reason="大带宽/高 RTT 场景建议 fq（公平排队 + pacing），配合 BBR 更佳；需 NIC 与内核支持且备份后应用。"
            [[ "$sup_fq" == "0" ]] && scene_reason="${scene_reason}（当前内核未检测到 fq 模块）"
            ;;
        *)
            scene_reason="通用场景保持当前 ${default_qdisc:-未知}；如需可评估 fq_codel。切换 qdisc 需先备份现有规则并单独确认。"
            ;;
    esac

    echo "qdisc 诊断完成："
    vno_log INFO "默认 qdisc=${default_qdisc:-未知}；主接口=${primary_iface:-无}"
    vno_log INFO "内核支持：fq=${sup_fq} fq_codel=${sup_fqcodel} cake=${sup_cake} pfifo_fast=${sup_pfifo}"
    vno_log INFO "业务场景(${profile})建议：${scene_rec}（${scene_reason}）"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"qdisc_manager\","
      echo "  \"stage\": 5,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"default_qdisc\": \"$(sanitize_json "$default_qdisc")\","
      echo "  \"primary_interface\": \"$(sanitize_json "$primary_iface")\","
      echo "  \"interfaces\": {"
      echo "$iface_entries"
      echo "  },"
      echo "  \"kernel_support\": {"
      echo "    \"fq\": ${sup_fq},"
      echo "    \"fq_codel\": ${sup_fqcodel},"
      echo "    \"cake\": ${sup_cake},"
      echo "    \"pfifo_fast\": ${sup_pfifo}"
      echo "  },"
      echo "  \"recommendation\": {"
      echo "    \"profile\": \"$(sanitize_json "$profile")\","
      echo "    \"suggested_qdisc\": \"$(sanitize_json "$scene_rec")\","
      echo "    \"reason\": \"$(sanitize_json "$scene_reason")\","
      echo "    \"require_confirm\": true"
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"qdisc 诊断完成，未修改任何规则；切换需备份现有 tc 规则并单独确认\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存 qdisc 数据到 ${JSON_FILE}"
    echo "阶段 5 模块 qdisc_manager 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
