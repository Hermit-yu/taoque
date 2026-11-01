#!/bin/bash
# Network-VNO-AI 主入口（vno-ai.sh）
# 任务书第 16 章：中文交互菜单 + 完整 CLI。
# 规则：调用同一套模块（modules/*），默认只读；应用/测速需确认（测速已默认允许并先明示流量）。
# 路径：从脚本位置解析项目根，不再硬编码 /opt/...，便于任意位置安装与测试。

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$SCRIPT_DIR/modules"
VNO_HOME="${VNO_HOME:-$SCRIPT_DIR}"
export VNO_HOME
VERSION="$(cat "${VNO_HOME}/VERSION" 2>/dev/null || echo '未知')"

run_mod() { bash "$MODULES/$1" "${@:2}"; }

show_menu() {
    echo "========== Network-VNO-AI 交互菜单 =========="
    echo "版本：${VERSION}    （项目根：${VNO_HOME}）"
    echo ""
    echo "  ── 当前实际状态 ──"
    run_mod status_panel.sh --compact 2>/dev/null | sed 's/^/  /'
    echo "  （完整状态与「已生效/未生效」逐项对照，请选 [17]）"
    echo ""
    echo "  [1]  完整检测（硬件/TCP/网络/拥塞控制/qdisc/网卡/MTU + 自适应计算）"
    echo "  [2]  硬件检测"
    echo "  [3]  TCP/IP 深度诊断"
    echo "  [4]  拥塞控制能力检测（BBR 能力门控）"
    echo "  [5]  队列(qdisc)诊断"
    echo "  [6]  网卡调优诊断（RSS/RPS/IRQ/Offload）"
    echo "  [7]  MTU/MSS 路径检测"
    echo "  [8]  网络质量测量（RTT/抖动/丢包）"
    echo "  [9]  带宽实测（默认允许，先明示流量）"
    echo "  [10] Bufferbloat 检测"
    echo "  [11] 自适应计算引擎（生成优化建议）"
    echo "  [12] 应用优化（备份→确认→应用→验证）"
    echo "  [13] 回滚到备份"
    echo "  [14] 性能基准闭环（基准→应用→复测→评价）"
    echo "  [15] 生成完整报告"
    echo "  [16] 长期监控（配置漂移/历史/重算）"
    echo "  [17] 查看实际应用状态面板（哪项已生效/未生效/未应用）"
    echo "  [0]  退出"
    echo "============================================"
    read -p "请输入选项数字（0-17）：" menu_choice || menu_choice=0
    case "$menu_choice" in
        1) run_mod system_detect.sh; run_mod tcp_detect.sh; run_mod network_quality.sh; run_mod congestion_control.sh; run_mod qdisc_manager.sh; run_mod nic_optimizer.sh; run_mod mtu_mss.sh; run_mod network_detect.sh; run_mod bandwidth_test.sh --yes; run_mod adaptive_engine.sh; echo "完整检测完成。可运行 [15] 生成报告，或 [12] 应用优化。" ;;
        2) run_mod system_detect.sh ;;
        3) run_mod tcp_detect.sh ;;
        4) run_mod congestion_control.sh ;;
        5) run_mod qdisc_manager.sh ;;
        6) run_mod nic_optimizer.sh ;;
        7) run_mod mtu_mss.sh ;;
        8) run_mod network_quality.sh ;;
        9) run_mod bandwidth_test.sh --yes ;;
        10) run_mod bufferbloat_test.sh ;;
        11) run_mod adaptive_engine.sh ;;
        12) run_mod safe_config.sh --apply ;;
        13) run_mod safe_config.sh --rollback ;;
        14) run_mod benchmark.sh --full ;;
        15) run_mod report_engine.sh ;;
        16) run_mod monitor.sh ;;
        17) run_mod status_panel.sh ;;
        0) echo "退出。数据与备份不会被删除。"; exit 0 ;;
        *) echo "无效选项：${menu_choice}" ;;
    esac
    echo "=== 本次菜单操作完成 ==="
    echo "执行时间：$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
}

usage() {
    cat <<EOF
Network-VNO-AI v${VERSION}
用法：vno-ai.sh [选项]
  无参数            进入中文交互菜单
  --all            完整检测 + 自适应计算（不含应用）
  --hardware       硬件检测
  --tcp            TCP/IP 深度诊断
  --congestion     拥塞控制能力检测
  --qdisc         队列(qdisc)诊断
  --nic           网卡调优诊断
  --mtu           MTU/MSS 路径检测
  --network       网络质量测量
  --bandwidth      带宽实测（默认允许，先明示流量）
  --bufferbloat   Bufferbloat 检测
  --recommend     自适应计算引擎（生成建议）
  --apply         应用优化（备份→确认→应用→验证）
  --rollback      回滚到备份
  --benchmark     性能基准闭环（基准→应用→复测→评价）
  --report        生成完整报告
  --monitor       长期监控
  --status        查看实际应用状态面板（逐项标出 已生效/未生效/未应用）
  --panel         同上（--status 的别名）
  --status-compact  状态速览（单行，适合脚本/巡检调用）
  --help          显示本帮助
说明：检测类默认只读；应用/回滚为高风险操作，需单独确认；测速默认允许但会先明示预计流量与时长。
EOF
}

main() {
    local cmd="${1:---menu}"
    case "$cmd" in
        --menu|"") show_menu ;;
        --all) run_mod system_detect.sh; run_mod tcp_detect.sh; run_mod network_quality.sh; run_mod congestion_control.sh; run_mod qdisc_manager.sh; run_mod nic_optimizer.sh; run_mod mtu_mss.sh; run_mod network_detect.sh; run_mod bandwidth_test.sh --yes; run_mod adaptive_engine.sh; echo "完整检测完成（未应用）。" ;;
        --hardware) run_mod system_detect.sh ;;
        --tcp) run_mod tcp_detect.sh ;;
        --congestion) run_mod congestion_control.sh ;;
        --qdisc) run_mod qdisc_manager.sh ;;
        --nic) run_mod nic_optimizer.sh ;;
        --mtu) run_mod mtu_mss.sh ;;
        --network) run_mod network_quality.sh ;;
        --bandwidth) run_mod bandwidth_test.sh --yes ;;
        --bufferbloat) run_mod bufferbloat_test.sh ;;
        --recommend) run_mod adaptive_engine.sh ;;
        --apply) run_mod safe_config.sh --apply ;;
        --rollback) run_mod safe_config.sh --rollback ;;
        --benchmark) run_mod benchmark.sh --full ;;
        --report) run_mod report_engine.sh ;;
        --monitor) run_mod monitor.sh ;;
        --status|--panel) run_mod status_panel.sh ;;
        --status-compact) run_mod status_panel.sh --compact ;;
        --help|-h) usage ;;
        *) echo "未知选项：${cmd}"; usage ;;
    esac
}

main "$@"
