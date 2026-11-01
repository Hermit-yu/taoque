#!/bin/bash
# Network-VNO-AI 高级诊断：MTU/MSS 路径检测（mtu_mss.sh）
# 任务书第 9 章（路径 MTU、MSS 钳制、 fragmentation）
# 规则：纯 Bash；依赖逐项探测；失败不崩溃；默认只读；大白话；统一 JSON 到 data/mtu_mss.json。
# 路径走 common.sh（SYS_ROOT 可重定向，便于测试）。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="MTU/MSS 路径检测"
JSON_FILE="${DATA_DIR}/mtu_mss.json"

list_ifaces() {
    if [[ -d "${SYS_ROOT}/class/net" ]]; then
        ls -1 "${SYS_ROOT}/class/net" 2>/dev/null | grep -v '^$' || true
    elif have_cmd ip; then
        ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' || true
    fi
}

# 取默认路由出口接口
default_iface() {
    if have_cmd ip; then
        ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' | head -1
    fi
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在检测各接口 MTU 与 TCP MSS（只读，不修改系统）..."

    local ifaces; ifaces="$(list_ifaces)"
    local def_if; def_if="$(default_iface)"
    local def_ipv4=""
    if have_cmd ip; then
        def_ipv4="$(ip -4 route get 8.8.8.8 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    fi

    local iface_entries=""
    local mismatches=0
    for ifc in $ifaces; do
        [[ "$ifc" == "lo" ]] && continue
        local mtu; mtu="$(read_sys "${SYS_ROOT}/class/net/${ifc}/mtu")"
        [[ -z "$mtu" ]] && mtu="1500"
        local mss_v4=$(( mtu - 40 ))
        local mss_v6=$(( mtu - 60 ))
        # 路径 MTU 探测（仅默认接口、且仅在有 ping 时）
        local pmtu="未探测"
        if [[ "$ifc" == "$def_if" && -n "$def_ipv4" && -n "$def_ipv4" ]] && have_cmd ping; then
            # 用 don't-fragment 探测，逐步探测易误报；这里只做一次基础探测并记录能力
            pmtu="探测需 DF 位(ping -M do)，默认不主动发包"
        fi
        # 合理性：标准以太网 MTU 1500；过低(<1280)可能影响性能；巨帧需对端一致
        local note="标准以太网 MTU=1500；IPv4 MSS=${mss_v4}，IPv6 MSS=${mss_v6}。"
        if [[ "${mtu:-1500}" -lt 1280 ]] 2>/dev/null; then
            note="${note} MTU 偏低(<1280)，可能需检查 PPPoE/隧道或开启 MSS 钳制。"
            mismatches=$(( mismatches + 1 ))
        elif [[ "${mtu:-1500}" -gt 1500 ]] 2>/dev/null; then
            note="${note} 巨帧(>1500)需整条路径设备一致，否则建议开启 TCP MSS 钳制(path MTU 发现或 iptables clamp)。"
        fi

        iface_entries="${iface_entries}    \"$ifc\": {
      \"mtu\": ${mtu:-1500},
      \"mss_ipv4\": ${mss_v4},
      \"mss_ipv6\": ${mss_v6},
      \"is_default_route\": $([[ "$ifc" == "$def_if" ]] && echo true || echo false),
      \"path_mtu_probe\": \"$(sanitize_json "$pmtu")\",
      \"note\": \"$(sanitize_json "$note")\"
    },
"
    done
    iface_entries="$(printf '%s' "$iface_entries" | sed '$ s/,$//')"
    [[ -z "$iface_entries" ]] && iface_entries="    \"(无可用接口)\": {}"

    local suggestion="未发现明显 MTU/MSS 异常。"
    [[ "$mismatches" -gt 0 ]] && suggestion="检测到 ${mismatches} 个接口 MTU 偏低，建议检查隧道/PPPoE 并考虑 MSS 钳制。"

    echo "MTU/MSS 检测完成："
    vno_log INFO "默认出口接口=${def_if:-无}；源IP=${def_ipv4:-无}"
    vno_log INFO "${suggestion}"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"mtu_mss\","
      echo "  \"stage\": 5,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"default_interface\": \"$(sanitize_json "$def_if")\","
      echo "  \"default_src_ip\": \"$(sanitize_json "$def_ipv4")\","
      echo "  \"interfaces\": {"
      echo "$iface_entries"
      echo "  },"
      echo "  \"summary\": {"
      echo "    \"low_mtu_ifaces\": ${mismatches},"
      echo "    \"suggestion\": \"$(sanitize_json "$suggestion")\""
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"MTU/MSS 检测完成，未修改任何设置；MSS 钳制属高级操作需单独确认\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存 MTU/MSS 数据到 ${JSON_FILE}"
    echo "阶段 5 模块 mtu_mss 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
