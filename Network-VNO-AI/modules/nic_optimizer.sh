#!/bin/bash
# Network-VNO-AI 高级诊断：网卡调优诊断（nic_optimizer.sh）
# 任务书第 7 章（RSS/RPS/IRQ/Offload/队列）
# 规则：纯 Bash；依赖逐项探测；失败不崩溃；默认只读；大白话；统一 JSON 到 data/nic.json。
# 路径走 common.sh（SYS_ROOT 可重定向，便于测试）。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="网卡调优诊断"
JSON_FILE="${DATA_DIR}/nic.json"

list_ifaces() {
    if [[ -d "${SYS_ROOT}/class/net" ]]; then
        ls -1 "${SYS_ROOT}/class/net" 2>/dev/null | grep -v '^$' || true
    elif have_cmd ip; then
        ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' || true
    fi
}

# 读取 /sys/class/net/<if>/<file>，缺失返回空
read_nic() {
    local ifc="$1" f="$2"
    read_sys "${SYS_ROOT}/class/net/${ifc}/${f}"
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在诊断网卡 RSS/RPS/IRQ/Offload/队列（只读，不修改系统）..."

    local ifaces; ifaces="$(list_ifaces)"
    local cpu_count=1
    if [[ -r "${PROC_ROOT}/cpuinfo" ]]; then
        cpu_count=$(grep -c '^processor' "${PROC_ROOT}/cpuinfo" 2>/dev/null || true); cpu_count=${cpu_count:-1}
    elif have_cmd nproc; then
        cpu_count="$(nproc 2>/dev/null || echo 1)"
    fi

    local iface_entries=""
    local summary_lines=""
    for ifc in $ifaces; do
        [[ "$ifc" == "lo" ]] && continue

        local mtu oper carrier speed
        mtu="$(read_nic "$ifc" mtu)"
        oper="$(read_nic "$ifc" operstate)"
        carrier="$(read_nic "$ifc" carrier)"
        speed="$(read_nic "$ifc" speed)"
        [[ "$speed" == "-1" || -z "$speed" ]] && speed="未知(需ethtool)"

        # 队列数量
        local rxq=0 txq=0
        if [[ -d "${SYS_ROOT}/class/net/${ifc}/queues" ]]; then
            rxq=$(ls -1 "${SYS_ROOT}/class/net/${ifc}/queues" 2>/dev/null | grep -c '^rx-' || true); rxq=${rxq:-0}
            txq=$(ls -1 "${SYS_ROOT}/class/net/${ifc}/queues" 2>/dev/null | grep -c '^tx-' || true); txq=${txq:-0}
        fi

        # RPS：rx-0 的 rps_cpus 是否开启（非全 0 表示已开启）
        local rps="未检测"
        if [[ -r "${SYS_ROOT}/class/net/${ifc}/queues/rx-0/rps_cpus" ]]; then
            local rpsv; rpsv="$(read_nic "$ifc" "queues/rx-0/rps_cpus" | tr -d '0')"
            [[ -z "$rpsv" ]] && rps="已开启(全0掩码)" || rps="未开启(掩码=$rpsv)"
        fi

        # ethtool 补充（可选）
        local driver="未知" offloads="未检测"
        if have_cmd ethtool; then
            driver="$(ethtool -i "$ifc" 2>/dev/null | awk -F': ' '/driver/{print $2; exit}')"
            driver="${driver:-未知}"
            local gro gso tso lro
            gro="$(ethtool -k "$ifc" 2>/dev/null | awk '/generic-receive-offload/{print $2}')"
            gso="$(ethtool -k "$ifc" 2>/dev/null | awk '/generic-segmentation-offload/{print $2}')"
            tso="$(ethtool -k "$ifc" 2>/dev/null | awk '/tcp-segmentation-offload/{print $2}')"
            lro="$(ethtool -k "$ifc" 2>/dev/null | awk '/large-receive-offload/{print $2}')"
            offloads="GRO=${gro:-?} GSO=${gso:-?} TSO=${tso:-?} LRO=${lro:-?}"
        fi

        # IRQ 亲和（粗粒度：统计该接口相关中断数）
        local irq_count="未知"
        if [[ -r "${PROC_ROOT}/interrupts" ]]; then
            irq_count=$(grep -c "$ifc" "${PROC_ROOT}/interrupts" 2>/dev/null || true); irq_count=${irq_count:-0}
        fi

        # 简易合理性建议
        local note="队列数=${rxq}/收 ${txq}/发；与 CPU 核数(${cpu_count})对比可评估是否需调 RSS/RPS。"
        if [[ "${rxq:-0}" -lt "${cpu_count:-1}" ]] 2>/dev/null; then
            note="${note} 接收队列少于 CPU 核数，多核高吞吐场景可考虑开启 RPS/调 RSS。"
        fi

        summary_lines="${summary_lines}    ${ifc}: mtu=${mtu} 状态=${oper} 速率=${speed} 队列=${rxq}/${txq} RPS=${rps} 驱动=${driver}"

        iface_entries="${iface_entries}    \"$ifc\": {
      \"mtu\": \"$(sanitize_json "$mtu")\",
      \"operstate\": \"$(sanitize_json "$oper")\",
      \"carrier\": \"$(sanitize_json "$carrier")\",
      \"speed\": \"$(sanitize_json "$speed")\",
      \"rx_queues\": ${rxq:-0},
      \"tx_queues\": ${txq:-0},
      \"rps\": \"$(sanitize_json "$rps")\",
      \"driver\": \"$(sanitize_json "$driver")\",
      \"offloads\": \"$(sanitize_json "$offloads")\",
      \"irq_related\": \"$(sanitize_json "$irq_count")\",
      \"note\": \"$(sanitize_json "$note")\"
    },
"
    done
    iface_entries="$(printf '%s' "$iface_entries" | sed '$ s/,$//')"
    [[ -z "$iface_entries" ]] && iface_entries="    \"(无可用接口)\": {}"

    echo "网卡调优诊断完成："
    [[ -n "$summary_lines" ]] && echo "$summary_lines" | while read -r l; do vno_log INFO "$l"; done
    vno_log INFO "提示：NIC 调优(RSS/RPS/IRQ 绑定)属高级操作，需结合业务与多队列网卡，默认不自动修改。"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"nic_optimizer\","
      echo "  \"stage\": 5,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"cpu_count\": ${cpu_count:-1},"
      echo "  \"interfaces\": {"
      echo "$iface_entries"
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"网卡调优诊断完成，未修改任何设置；高级调优需单独确认并备份\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存网卡诊断数据到 ${JSON_FILE}"
    echo "阶段 5 模块 nic_optimizer 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
