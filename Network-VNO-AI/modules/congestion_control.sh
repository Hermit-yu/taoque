#!/bin/bash
# Network-VNO-AI 高级诊断：拥塞控制能力检测（congestion_control.sh）
# 任务书第 5.2 章 + 需求 2（能力门控，不把 BBR 当万能）
# 规则：纯 Bash；依赖逐项探测；失败不崩溃；默认只读；大白话；统一 JSON 到 data/congestion_control.json。
# 路径走 common.sh（PROC_ROOT/SYS_ROOT 可重定向，便于测试）。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="拥塞控制能力检测"
JSON_FILE="${DATA_DIR}/congestion_control.json"

# 内核版本解析为可比较的整数 (major*1000 + minor)
kernel_version_code() {
    local kv
    kv="$(read_sysctl kernel.osrelease 2>/dev/null || uname -r 2>/dev/null || echo "0.0")"
    local maj min
    maj="$(echo "$kv" | cut -d. -f1)"; min="$(echo "$kv" | cut -d. -f2)"
    maj="${maj:-0}"; min="${min:-0}"
    echo $(( maj * 1000 + min ))
}

# 读取虚拟化类型（优先硬件检测结果，否则探测）
detect_virtual() {
    if [[ -r "${DATA_DIR}/hardware.json" ]]; then
        local v; v="$(get_json_field "${DATA_DIR}/hardware.json" is_virtual)"
        [[ -n "$v" ]] && { echo "$v"; return; }
    fi
    local vz="未知"
    if [[ -r "${PROC_ROOT}/vz" ]]; then vz="OpenVZ(受限虚拟化)";
    elif have_cmd systemd-detect-virt; then vz="$(systemd-detect-virt 2>/dev/null || echo 未知)";
    fi
    echo "$vz"
}

# 判断虚拟化是否可能限制网络堆栈（用户态/共享内核）
is_restricted_virt() {
    local v="$1"
    if echo "$v" | grep -qiE "openvz|lxc|受限|docker|container|virt|kvm|qemu|vmware|xen|hyperv|microsoft"; then
        # 进一步区分：OpenVZ/LXC 共享内核，CC/qdisc 往往不生效；完整虚拟化(KVM/Xen HVM)一般可控
        if echo "$v" | grep -qiE "openvz|lxc|受限"; then echo "1"; else echo "0"; fi
    else
        echo "0"
    fi
}

# 判断某拥塞控制是否已实际注册（在 available 列表中）
algo_registered() {
    local algo="$1" list="$2"
    echo " $list " | grep -q " $algo " && echo "1" || echo "0"
}

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在检测内核拥塞控制模块与能力（只读，不修改系统）..."

    local avail cur_cc default_qdisc bbr_loaded
    avail="$(read_sysctl net.ipv4.tcp_available_congestion_control)"
    cur_cc="$(read_sysctl net.ipv4.tcp_congestion_control)"
    default_qdisc="$(read_sysctl net.core.default_qdisc)"

    # BBR 模块是否加载
    bbr_loaded="未加载"
    if have_cmd lsmod; then
        lsmod 2>/dev/null | grep -q 'tcp_bbr' && bbr_loaded="已加载" || bbr_loaded="未加载"
    elif [[ -r "${PROC_ROOT}/modules" ]]; then
        grep -q 'tcp_bbr' "${PROC_ROOT}/modules" 2>/dev/null && bbr_loaded="已加载" || bbr_loaded="未加载"
    fi

    local kver; kver="$(kernel_version_code)"
    local bbr_min=4009   # BBR v1 进入主线 4.9
    local bbr_kernel_ok="false"
    (( kver >= bbr_min )) && bbr_kernel_ok="true"

    local vtype; vtype="$(detect_virtual)"
    local restricted; restricted="$(is_restricted_virt "$vtype")"

    # 逐算法能力判定
    local algo_entries=""
    local check_list="bbr cubic reno vegas westwood htcp"
    for a in $check_list; do
        local status="不可用"
        if [[ "$(algo_registered "$a" "$avail")" == "1" ]]; then
            status="已注册(内核内置或已加载模块)"
        elif [[ "$a" == "bbr" && "$bbr_kernel_ok" == "true" ]]; then
            status="内核支持(>=4.9)但未加载模块，可 modprobe tcp_bbr"
        fi
        algo_entries="${algo_entries}    \"$a\": \"${status}\","$'\n'
    done
    # 去掉最后一行的尾逗号
    algo_entries="$(printf '%s' "$algo_entries" | sed '$ s/,$//')"

    # BBR 适用性结论（需求 2：不盲目推荐）
    local bbr_rec="保持当前 ${cur_cc:-未知}"
    local bbr_reason=""
    if [[ "$(algo_registered bbr "$avail")" == "1" ]]; then
        if [[ "$restricted" == "1" ]]; then
            bbr_reason="BBR 虽已注册，但当前为受限虚拟化(共享内核)，切换拥塞控制可能不生效，保持当前 ${cur_cc} 更稳妥。"
        else
            bbr_reason="BBR 已实际注册且环境可控，适用于高带宽/高 RTT/长肥管道；低延迟短连接场景未必优于 CUBIC。是否切换需结合实际测速，单独确认后再应用。"
        fi
    else
        if [[ "$bbr_kernel_ok" == "true" ]]; then
            bbr_reason="内核 >=4.9 支持 BBR，但当前未注册(需 modprobe tcp_bbr 或编译进内核)。不强制升级内核；保持当前 ${cur_cc}。"
        else
            bbr_reason="内核 <4.9 不支持 BBR，不强制升级内核；保持当前 ${cur_cc}(CUBIC 类默认最稳)。"
        fi
    fi

    # 当前算法诊断
    local cur_note=""
    case "$cur_cc" in
        *bbr*)  cur_note="当前 BBR：适合长肥管道；低延迟短连接未必最优，需测速佐证。" ;;
        *cubic*) cur_note="当前 CUBIC：Linux 默认，绝大多数场景稳定可靠，是稳妥基准。" ;;
        *reno*)  cur_note="当前 Reno：经典算法，低带宽低延迟可用，高 BDP 吞吐受限。" ;;
        *)       cur_note="当前 ${cur_cc:-未知}：建议结合业务与测速判断适用性。" ;;
    esac

    echo "拥塞控制能力检测完成："
    vno_log INFO "当前算法=${cur_cc:-未知}；可选=[${avail:-未知}]；默认qdisc=${default_qdisc:-未知}"
    vno_log INFO "BBR 模块加载=${bbr_loaded}；内核版本码=${kver}(BBR需>=4009)；虚拟化=${vtype}"
    vno_log INFO "受限虚拟化=${restricted}（1=共享内核可能不生效）"
    vno_log INFO "${cur_note}"
    vno_log INFO "BBR 适用性：${bbr_reason}"

    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"congestion_control\","
      echo "  \"stage\": 5,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"kernel\": {"
      echo "    \"version_code\": ${kver},"
      echo "    \"bbr_min_supported_code\": ${bbr_min},"
      echo "    \"bbr_kernel_supported\": ${bbr_kernel_ok}"
      echo "  },"
      echo "  \"virtualization\": {"
      echo "    \"type\": \"$(sanitize_json "$vtype")\","
      echo "    \"is_restricted\": ${restricted}"
      echo "  },"
      echo "  \"current\": {"
      echo "    \"algorithm\": \"$(sanitize_json "$cur_cc")\","
      echo "    \"available\": \"$(sanitize_json "$avail")\","
      echo "    \"default_qdisc\": \"$(sanitize_json "$default_qdisc")\","
      echo "    \"bbr_module_loaded\": \"$(sanitize_json "$bbr_loaded")\","
      echo "    \"note\": \"$(sanitize_json "$cur_note")\""
      echo "  },"
      echo "  \"algorithm_capabilities\": {"
      echo "$algo_entries"
      echo "  },"
      echo "  \"bbr_assessment\": {"
      echo "    \"registered\": $(algo_registered bbr "$avail"),"
      echo "    \"module_loaded\": \"$(sanitize_json "$bbr_loaded")\","
      echo "    \"recommendation\": \"$(sanitize_json "$bbr_rec")\","
      echo "    \"reason\": \"$(sanitize_json "$bbr_reason")\","
      echo "    \"require_confirm\": true"
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"拥塞控制能力检测完成，未修改任何内核参数；BBR 推荐遵循能力门控原则\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存拥塞控制能力数据到 ${JSON_FILE}"
    echo "阶段 5 模块 congestion_control 完成。"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
