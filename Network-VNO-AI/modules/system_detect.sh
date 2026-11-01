#!/bin/bash
# Network-VNO-AI 阶段 1：系统与硬件画像模块（system_detect.sh）
# 任务书第 4 章：CPU / 内存 / 网卡 / 系统 全面画像
# 规则：纯 Bash（核心零 Python 依赖）；依赖逐项探测；缺失工具优雅降级；默认只读；大白话提示；统一 JSON。
# 所有路径走 common.sh（VNO_HOME / PROC_ROOT / SYS_ROOT）。

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME="系统与硬件画像"
JSON_FILE="${DATA_DIR}/hardware.json"

main() {
    echo "=== $MODULE_NAME ==="
    echo "正在读取系统与硬件信息（只读，不修改任何配置）..."

    # ---------------- CPU 检测（4.1） ----------------
    cpu_model="未知"; cpu_arch="未知"; cpu_cores_phys=0; cpu_cores_log=0
    cpu_freq_mhz="未知"; cpu_virt="未知"; cpu_steal="0.0"
    cpu_load1="0"; cpu_load5="0"; cpu_load15="0"; cpu_single_core_load="未知"
    numa_nodes=1; cpu_topology="未知"

    if [[ -r "${PROC_ROOT}/cpuinfo" ]]; then
        cpu_model=$(grep -m1 '^model name' "${PROC_ROOT}/cpuinfo" 2>/dev/null | cut -d':' -f2 | sed 's/^ *//')
        [[ -z "$cpu_model" ]] && cpu_model=$(grep -m1 '^Hardware' "${PROC_ROOT}/cpuinfo" 2>/dev/null | cut -d':' -f2 | sed 's/^ *//')
        [[ -z "$cpu_model" ]] && cpu_model="未知"
        cpu_cores_phys=$(grep -c '^processor' "${PROC_ROOT}/cpuinfo" 2>/dev/null || true); cpu_cores_phys=${cpu_cores_phys:-0}
        cpu_cores_log=$(grep -c '^processor' "${PROC_ROOT}/cpuinfo" 2>/dev/null || true); cpu_cores_log=${cpu_cores_log:-0}
        cpu_freq_mhz=$(grep -m1 '^cpu MHz' "${PROC_ROOT}/cpuinfo" 2>/dev/null | cut -d: -f2 | tr -d ' ' | cut -d'.' -f1)
        [[ -z "$cpu_freq_mhz" ]] && cpu_freq_mhz=$(grep -m1 '^CPU max MHz' "${PROC_ROOT}/cpuinfo" 2>/dev/null | cut -d: -f2 | tr -d ' ' | cut -d'.' -f1)
        [[ -z "$cpu_freq_mhz" ]] && cpu_freq_mhz="未知"
    fi
    cpu_arch=$(uname -m 2>/dev/null || echo "未知")
    # 逻辑核优先取 cpuinfo 计数（更准确），仅在读不到时回退 nproc
    [[ "${cpu_cores_log:-0}" -lt 1 ]] && cpu_cores_log=$(nproc 2>/dev/null || echo 1)

    # 虚拟化类型识别（4.1 重点：KVM/QEMU/VMware/Xen/Hyper-V/OpenVZ/LXC/Docker）
    if have_cmd systemd-detect-virt; then
        cpu_virt=$(systemd-detect-virt 2>/dev/null || echo "未知（systemd-detect-virt 无输出）")
    fi
    if [[ "$cpu_virt" == "未知"* || -z "$cpu_virt" ]]; then
        if [[ -r "${PROC_ROOT}/1/cgroup" ]] && grep -qiE 'docker|lxc|kubepods' "${PROC_ROOT}/1/cgroup" 2>/dev/null; then
            cpu_virt="容器（LXC/Docker，从 cgroup 识别）"
        elif [[ -d "${PROC_ROOT}/xen" ]]; then
            cpu_virt="Xen 虚拟化"
        elif grep -qiE 'kvm|qemu' "${PROC_ROOT}/cpuinfo" 2>/dev/null; then
            cpu_virt="KVM/QEMU 虚拟化（从 cpuinfo 推测）"
        elif grep -qiE 'vmware|hypervisor' "${PROC_ROOT}/cpuinfo" 2>/dev/null; then
            cpu_virt="VMware/Hyper-V 虚拟化（从 cpuinfo 推测）"
        else
            cpu_virt="未识别到明显虚拟化标记（可能为物理机）"
        fi
    fi

    # CPU 使用率与 Steal（4.1）：基于 /proc/stat 瞬时采样
    if [[ -r "${PROC_ROOT}/stat" ]]; then
        read -r _ u n i s irq sirq steal rest < <(grep '^cpu ' "${PROC_ROOT}/stat" 2>/dev/null)
        local total=$(( ${u:-0}+${n:-0}+${i:-0}+${s:-0}+${irq:-0}+${sirq:-0}+${steal:-0} ))
        [[ "$total" -gt 0 ]] && cpu_steal=$(awk "BEGIN{printf \"%.1f\", 100*(${steal:-0})/${total}}") || cpu_steal="0.0"
    fi
    # 系统负载
    if [[ -r "${PROC_ROOT}/loadavg" ]]; then
        read -r cpu_load1 cpu_load5 cpu_load15 _ < "${PROC_ROOT}/loadavg" 2>/dev/null
    fi
    # 单核负载（负载/逻辑核数）
    if [[ "${cpu_cores_log:-0}" -gt 0 ]]; then
        cpu_single_core_load=$(awk "BEGIN{printf \"%.2f\", ${cpu_load1:-0}/${cpu_cores_log}}")
    fi
    # NUMA 节点（4.1）
    if [[ -d "${SYS_ROOT}/devices/system/node" ]]; then
        numa_nodes=$(ls -d "${SYS_ROOT}/devices/system/node"/node* 2>/dev/null | wc -l)
        [[ "$numa_nodes" -lt 1 ]] && numa_nodes=1
    fi
    cpu_topology="NUMA节点=${numa_nodes}，逻辑核=${cpu_cores_log}，物理核=${cpu_cores_phys}"

    # ---------------- 内存检测（4.2） ----------------
    mem_total_kb=0; mem_avail_kb=0; mem_buffers_kb=0; mem_cached_kb=0
    mem_swap_total_kb=0; mem_swap_free_kb=0
    if [[ -r "${PROC_ROOT}/meminfo" ]]; then
        mem_total_kb=$(awk '/^MemTotal:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
        mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
        [[ -z "$mem_avail_kb" ]] && mem_avail_kb=$(awk '/^MemFree:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
        mem_buffers_kb=$(awk '/^Buffers:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
        mem_cached_kb=$(awk '/^Cached:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
        mem_swap_total_kb=$(awk '/^SwapTotal:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
        mem_swap_free_kb=$(awk '/^SwapFree:/{print $2}' "${PROC_ROOT}/meminfo" 2>/dev/null)
    fi
    mem_total_mb=$(( ${mem_total_kb:-0} / 1024 ))
    mem_avail_mb=$(( ${mem_avail_kb:-0} / 1024 ))
    mem_buffers_mb=$(( ${mem_buffers_kb:-0} / 1024 ))
    mem_cached_mb=$(( ${mem_cached_kb:-0} / 1024 ))
    mem_swap_total_mb=$(( ${mem_swap_total_kb:-0} / 1024 ))
    mem_swap_free_mb=$(( ${mem_swap_free_kb:-0} / 1024 ))
    # 内存压力（可用/总量，低于 10% 视为紧张，任务书 4.2 内存压力）
    mem_pressure="未知"
    if [[ "${mem_total_mb:-0}" -gt 0 ]]; then
        mem_avail_pct=$(awk "BEGIN{printf \"%.0f\", 100*${mem_avail_mb}/(${mem_total_mb})}")
        if [[ "$mem_avail_pct" -lt 10 ]]; then mem_pressure="紧张（可用不足 10%）"
        elif [[ "$mem_avail_pct" -lt 25 ]]; then mem_pressure="偏紧（可用不足 25%）"
        else mem_pressure="充足（可用 ${mem_avail_pct}%）"; fi
    fi
    # 内存分级预算（10.3：不能仅按总内存；此处给出分级文字，具体预算在 adaptive_engine）
    if [[ "${mem_total_mb}" -lt 512 ]]; then mem_budget_tier="超小内存（<512MB）→ 仅做保守修复"
    elif [[ "${mem_total_mb}" -lt 2048 ]]; then mem_budget_tier="小内存（512MB-2GB）→ 保守调整"
    elif [[ "${mem_total_mb}" -lt 8192 ]]; then mem_budget_tier="中等内存（2GB-8GB）→ 均衡可行"
    else mem_budget_tier="大内存（≥8GB）→ 可高性能，仍需结合实际"; fi

    # ---------------- 网卡检测（4.3） ----------------
    default_if="未知"
    if have_cmd ip; then
        default_if=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
        [[ -z "$default_if" ]] && default_if=$(ip route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' | head -1)
    elif have_cmd route; then
        default_if=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $8;exit}')
    fi
    [[ -z "$default_if" ]] && default_if="未知"

    if_name="$default_if"; if_mtu=0; if_type="未知"; if_is_virtual="未知"
    if_driver="未知"; if_speed="未知"; if_rx_bytes=0; if_tx_bytes=0
    if_rx_drop=0; if_tx_drop=0; if_rx_err=0; if_tx_err=0; if_ipv4="未知"; if_ipv6="未知"
    rx_queues=0; tx_queues=0

    if [[ "$if_name" != "未知" ]]; then
        local_sys="${SYS_ROOT}/class/net/${if_name}"
        if [[ -r "${local_sys}/mtu" ]]; then
            if_mtu=$(read_sys "${local_sys}/mtu")
            if_type=$(read_sys "${local_sys}/type")
            if_rx_bytes=$(read_sys "${local_sys}/statistics/rx_bytes")
            if_tx_bytes=$(read_sys "${local_sys}/statistics/tx_bytes")
            if_rx_drop=$(read_sys "${local_sys}/statistics/rx_drop")
            if_tx_drop=$(read_sys "${local_sys}/statistics/tx_drop")
            if_rx_err=$(read_sys "${local_sys}/statistics/rx_errors")
            if_tx_err=$(read_sys "${local_sys}/statistics/tx_errors")
            # 队列数量
            rx_queues=$(ls -d "${local_sys}/queues/rx-"* 2>/dev/null | wc -l)
            tx_queues=$(ls -d "${local_sys}/queues/tx-"* 2>/dev/null | wc -l)
            # 虚拟网卡判定（4.3：必须区分虚拟/物理；虚拟网卡标称速率不能当作公网带宽）
            case "$if_name" in
                lo|dummy*|bond*|br*|virbr*|docker*|veth*|tun*|tap*) if_is_virtual="虚拟网卡（桥接/容器/隧道/回环）" ;;
                *)
                    if [[ -d "${local_sys}/device" ]]; then if_is_virtual="物理网卡（存在 device 链接）"
                    else if_is_virtual="虚拟化环境网卡（无 device 链接，速率不可当作真实公网带宽）"; fi ;;
            esac
            # 驱动
            if [[ -d "${local_sys}/device/driver" ]]; then
                if_driver=$(basename "$(readlink "${local_sys}/device/driver" 2>/dev/null)" 2>/dev/null || echo "未知")
            fi
            # 链路速率（虚拟网卡可能为 -1 或无意义）
            if [[ -r "${local_sys}/speed" ]]; then
                local sp; sp=$(read_sys "${local_sys}/speed")
                if [[ "$sp" =~ ^[0-9]+$ ]] && [[ "$sp" -gt 0 ]]; then if_speed="${sp} Mbps"; else if_speed="未知（虚拟网卡无真实速率）"; fi
            fi
        fi
        # IP 地址（区分 IPv4 / IPv6，8.1 要求）
        if have_cmd ip; then
            if_ipv4=$(ip -4 addr show "$if_name" 2>/dev/null | awk '/inet /{print $2;exit}')
            if_ipv6=$(ip -6 addr show "$if_name" 2>/dev/null | awk '/inet6 /{print $2;exit}')
            [[ -z "$if_ipv4" ]] && if_ipv4="无IPv4"
            [[ -z "$if_ipv6" ]] && if_ipv6="无IPv6"
        fi
    fi

    # ---------------- 系统检测（4.4） ----------------
    kernel_ver=$(uname -r 2>/dev/null || echo "未知")
    distro="未知"
    if [[ -r "${ETC_ROOT}/os-release" ]]; then
        distro=$(. "${ETC_ROOT}/os-release" 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-未知}}")
    elif [[ -r "${ETC_ROOT}/redhat-release" ]]; then
        distro=$(cat "${ETC_ROOT}/redhat-release" 2>/dev/null | head -1)
    fi
    [[ -z "$distro" ]] && distro="未知"

    sysctl_supported="未知"; tc_supported="未知"; ethtool_supported="未知"; iproute2_ver="未知"
    have_cmd sysctl && sysctl_supported="支持" || sysctl_supported="不支持（无 sysctl 命令）"
    have_cmd tc && tc_supported="支持" || tc_supported="不支持（队列诊断依赖 tc）"
    have_cmd ethtool && ethtool_supported="支持" || ethtool_supported="不支持（网卡 Offload 诊断依赖 ethtool）"
    have_cmd ip && iproute2_ver=$(ip -V 2>/dev/null | awk '{print $2}' || echo "未知")
    systemd_status="未知"
    if have_cmd systemctl; then
        systemctl is-active --quiet systemd 2>/dev/null && systemd_status="运行中" || systemd_status="已安装但未作为 init"
    else systemd_status="无 systemd"; fi
    # 防火墙工具
    fw_tool="无"; have_cmd iptables && fw_tool="iptables"; have_cmd nft && fw_tool="nftables"; have_cmd ufw && fw_tool="ufw"

    # ---------------- 输出（大白话） ----------------
    echo "系统检测完成："
    vno_log INFO "CPU：${cpu_model}（${cpu_arch}，物理核 ${cpu_cores_phys}/逻辑核 ${cpu_cores_log}，频率约 ${cpu_freq_mhz}MHz）"
    vno_log INFO "虚拟化：${cpu_virt}；Steal ${cpu_steal}%（>5% 说明虚拟化资源争抢明显）"
    vno_log INFO "负载：1/5/15 分钟 = ${cpu_load1}/${cpu_load5}/${cpu_load15}；单核负载 ${cpu_single_core_load}；${cpu_topology}"
    vno_log INFO "内存：总 ${mem_total_mb}MB / 可用 ${mem_avail_mb}MB（缓冲 ${mem_buffers_mb} + 缓存 ${mem_cached_mb}）/ 交换 ${mem_swap_total_mb}MB（可用 ${mem_swap_free_mb}）；压力：${mem_pressure}"
    vno_log INFO "内存预算判断：${mem_budget_tier}"
    vno_log INFO "默认网卡：${if_name}（MTU=${if_mtu}，类型=${if_type}，${if_is_virtual}）"
    vno_log INFO "  驱动=${if_driver}，链路速率=${if_speed}，RX队列=${rx_queues}/TX队列=${tx_queues}"
    vno_log INFO "  IPv4=${if_ipv4}，IPv6=${if_ipv6}"
    vno_log INFO "  收发字节 RX=${if_rx_bytes} TX=${if_tx_bytes}；丢包 RX=${if_rx_drop}/TX=${if_tx_drop}；错误 RX=${if_rx_err}/TX=${if_tx_err}"
    vno_log INFO "系统：${distro}；内核 ${kernel_ver}；sysctl=${sysctl_supported}，tc=${tc_supported}，ethtool=${ethtool_supported}，iproute2=${iproute2_ver}；防火墙=${fw_tool}"

    # ---------------- 写入 JSON ----------------
    ensure_dirs
    {
      echo "{"
      echo "  \"project\": \"Network-VNO-AI\","
      echo "  \"module\": \"system_detect\","
      echo "  \"stage\": 1,"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"hardware\": {"
      echo "    \"cpu_model\": \"$(sanitize_json "$cpu_model")\","
      echo "    \"cpu_arch\": \"$(sanitize_json "$cpu_arch")\","
      echo "    \"cpu_cores_physical\": ${cpu_cores_phys:-0},"
      echo "    \"cpu_cores_logical\": ${cpu_cores_log:-0},"
      echo "    \"cpu_freq_mhz\": \"$(sanitize_json "$cpu_freq_mhz")\","
      echo "    \"cpu_virt_type\": \"$(sanitize_json "$cpu_virt")\","
      echo "    \"cpu_steal_percent\": \"${cpu_steal:-0.0}\","
      echo "    \"cpu_load_1min\": \"${cpu_load1:-0}\","
      echo "    \"cpu_load_5min\": \"${cpu_load5:-0}\","
      echo "    \"cpu_load_15min\": \"${cpu_load15:-0}\","
      echo "    \"cpu_single_core_load\": \"${cpu_single_core_load:-0}\","
      echo "    \"numa_nodes\": ${numa_nodes:-1},"
      echo "    \"cpu_topology\": \"$(sanitize_json "$cpu_topology")\""
      echo "  },"
      echo "  \"memory\": {"
      echo "    \"mem_total_mb\": ${mem_total_mb:-0},"
      echo "    \"mem_available_mb\": ${mem_avail_mb:-0},"
      echo "    \"mem_buffers_mb\": ${mem_buffers_mb:-0},"
      echo "    \"mem_cached_mb\": ${mem_cached_mb:-0},"
      echo "    \"mem_swap_total_mb\": ${mem_swap_total_mb:-0},"
      echo "    \"mem_swap_free_mb\": ${mem_swap_free_mb:-0},"
      echo "    \"mem_pressure\": \"$(sanitize_json "$mem_pressure")\","
      echo "    \"mem_budget_tier\": \"$(sanitize_json "$mem_budget_tier")\""
      echo "  },"
      echo "  \"network_base\": {"
      echo "    \"default_interface\": \"$(sanitize_json "$if_name")\","
      echo "    \"mtu\": ${if_mtu:-0},"
      echo "    \"interface_type\": \"$(sanitize_json "$if_type")\","
      echo "    \"is_virtual\": \"$(sanitize_json "$if_is_virtual")\","
      echo "    \"driver\": \"$(sanitize_json "$if_driver")\","
      echo "    \"link_speed\": \"$(sanitize_json "$if_speed")\","
      echo "    \"rx_queues\": ${rx_queues:-0},"
      echo "    \"tx_queues\": ${tx_queues:-0},"
      echo "    \"ipv4\": \"$(sanitize_json "$if_ipv4")\","
      echo "    \"ipv6\": \"$(sanitize_json "$if_ipv6")\","
      echo "    \"rx_bytes\": ${if_rx_bytes:-0},"
      echo "    \"tx_bytes\": ${if_tx_bytes:-0},"
      echo "    \"rx_drop\": ${if_rx_drop:-0},"
      echo "    \"tx_drop\": ${if_tx_drop:-0},"
      echo "    \"rx_errors\": ${if_rx_err:-0},"
      echo "    \"tx_errors\": ${if_tx_err:-0}"
      echo "  },"
      echo "  \"system\": {"
      echo "    \"kernel_version\": \"$(sanitize_json "$kernel_ver")\","
      echo "    \"distro\": \"$(sanitize_json "$distro")\","
      echo "    \"cpu_arch\": \"$(sanitize_json "$cpu_arch")\","
      echo "    \"sysctl_supported\": \"$(sanitize_json "$sysctl_supported")\","
      echo "    \"tc_supported\": \"$(sanitize_json "$tc_supported")\","
      echo "    \"ethtool_supported\": \"$(sanitize_json "$ethtool_supported")\","
      echo "    \"iproute2_version\": \"$(sanitize_json "$iproute2_ver")\","
      echo "    \"systemd_status\": \"$(sanitize_json "$systemd_status")\","
      echo "    \"firewall_tool\": \"$(sanitize_json "$fw_tool")\""
      echo "  },"
      echo "  \"status\": \"completed\","
      echo "  \"notes\": \"阶段1系统硬件画像完成，未修改任何系统配置\""
      echo "}"
    } > "$JSON_FILE"

    echo "已保存硬件画像到 ${JSON_FILE}"
    echo "阶段 1 模块 system_detect 完成。"
}

main "$@"
