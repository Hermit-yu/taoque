#!/usr/bin/env bash
# ============================================================================
# tcp-window-optimizer.sh — 主入口（任务书 §2 + §12）
# 纪律：默认只读、不改动系统；应用需 root+--apply+确认；不要求重启。
# 退出码：0 成功 | 1 用法/参数错误 | 2 前置检查失败 | 3 权限不足
# ============================================================================
set -u   # 未定义变量即报；任务书明确【禁止全局 set -e】，故只加 -u

TWO_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${TWO_LIB_DIR:-$SCRIPT_DIR/src/lib}"

# ---- 载入所有引擎模块（硬校验：缺文件立即明确报错，避免满屏 command not found）----
TWO_LIB_FILES=(common hwdetect sysdetect tcpcaps netdetect bdp configmgmt apply report)
two_load_libs() {
  local m missing=0
  for m in "${TWO_LIB_FILES[@]}"; do
    [[ -r "$LIB_DIR/$m.sh" ]] || { echo "出错：缺少引擎模块（$m），请确认主脚本与 src/lib/ 一起运行" >&2; missing=1; }
  done
  if (( missing )); then
    cat >&2 <<'EOF'

本工具必须由【主脚本 + src/lib/ 共9个模块】一起运行，不能只拷走主脚本。
请确认运行目录结构（或先用环境变量 TWO_LIB_DIR 指定模块目录）:

  <项目根>/
    tcp-window-optimizer.sh
    src/lib/{common,hwdetect,sysdetect,tcpcaps,netdetect,bdp,configmgmt,apply,report}.sh

修复方法（任选其一）:
  1) 把整个项目目录拷齐（主脚本 + src/lib/ 一起），再从项目根运行;
  2) 运行前指定模块目录:  TWO_LIB_DIR=/path/to/src/lib ./tcp-window-optimizer.sh --detect
EOF
    return 2
  fi
  local m2
  for m2 in "${TWO_LIB_FILES[@]}"; do
    source "$LIB_DIR/$m2.sh" || { echo "出错：加载模块失败（$m2），检查文件完整性" >&2; return 2; }
  done
  return 0
}

if ! two_load_libs; then
  exit 2
fi

usage() {
  cat <<EOF
TCP Window Optimizer v$TWO_VERSION  —  默认只读, 不改动系统

用法:
  ./tcp-window-optimizer.sh                 # 进入交互菜单
  ./tcp-window-optimizer.sh --detect        # 只读检测 + 计算 + 生成报告
  ./tcp-window-optimizer.sh --status        # 查看当前 TCP 参数
  ./tcp-window-optimizer.sh --apply [--yes]  # 应用推荐(需 root + 确认)
  ./tcp-window-optimizer.sh --rollback      # 回滚到应用前(需 root)
  ./tcp-window-optimizer.sh --report        # 查看最近检测报告

选项:
  --bandwidth <Mbps>      显式指定公网带宽(覆盖自动判断)
  --ping-target <IP>...   指定 RTT 探测目标(空格分隔多个)
  --enable-iperf3         授权后启用 iperf3 主动测速
  --no-speedtest          关闭默认主动网速测试(小流量参考测带宽)
  --speedtest-url <URL>   指定网速测试下载目标
  --speedtest-mb <N>      测速下载量上限(MB, 默认20)
  --yes                   应用时跳过交互确认(配合 --apply)
  -h, --help              本帮助
  --version               打印版本

说明:
  • 默认【只读】, 不会修改任何系统参数; 只有 --apply 且 root 且确认后才写。
  • 数据源可用 TWO_BASE_PROC / TWO_BASE_SYS 覆盖(测试注入)。
  • 全程不要求重启。
EOF
}

# ---- 解析参数（§2）----
two_parse_args() {
  TWO_CMD="menu"
  TWO_YES="${TWO_YES:-0}"
  local positional=0
  while (( $# )); do
    case "$1" in
      -h|--help)     usage; exit 0;;
      --version)     printf 'tcp-window-optimizer %s\n' "$TWO_VERSION"; exit 0;;
      --detect)      TWO_CMD="detect";;
      --status)      TWO_CMD="status";;
      --apply)       TWO_CMD="apply";;
      --rollback)    TWO_CMD="rollback";;
      --report)      TWO_CMD="report";;
      --yes)         TWO_YES=1;;
      --bandwidth)   shift
        [[ $# -ge 1 ]] || { two_log_if ERROR "--bandwidth 需要一个 <Mbps> 值"; exit 1; }
        TWO_BANDWIDTH_Mbps="$1";;
      --ping-target) shift; TWO_PING_TARGETS="${1:-}";;
      --enable-iperf3) TWO_ENABLE_IPERF3=1;;
      --no-speedtest) TWO_DISABLE_SPEEDTEST=1;;
      --speedtest-url) shift; TWO_SPEEDTEST_URL="${1:-}";;
      --speedtest-mb) shift; TWO_SPEEDTEST_MB="${1:-}";;
      --)            :;;
      -*)            two_log_if ERROR "未知选项: $1"; usage; exit 1;;
      *)             positional=$((positional+1)); TWO_CMD="detect";;
    esac
    shift
  done
}

# ---- 一次完整检测+计算+报告（只读）----
two_run_detect() {
  two_log_if INFO "开始检测 (只读, 不改动系统)…"
  two_cfg_ensure_dirs
  two_hw_detect_all
  two_sys_detect
  two_tcp_detect_all
  two_net_detect_all
  two_calc_engine
  two_cfg_check_conflicts
  two_report_generate
  return 0
}

# ---- 交互菜单（§12）----
two_run_menu() {
  local choice
  while :; do
    echo
    echo "================ TCP Window Optimizer ================"
    echo "  1) 运行完整检测(只读, 生成报告)"
    echo "  2) 查看当前 TCP 参数"
    echo "  3) 应用推荐参数(需 root + 确认, 会备份)"
    echo "  4) 回滚到应用前(需 root)"
    echo "  5) 查看最近检测报告"
    echo "  6) 退出"
    echo "======================================================="
    read -r -p "选择 [1-6]: " choice || choice="6"
    case "$choice" in
      1) two_run_detect ;;
      2) two_report_status_view ;;
      3)
         two_run_detect >/dev/null   # 先算好 REC/CFG
         echo "-- 菜单选择: 应用推荐参数 --"
         two_apply_run && two_log_if INFO "已应用" || two_log_if INFO "应用结束(result=${APPLY[result]:-})"
         ;;
      4)
         two_cfg_ensure_dirs
         two_apply_rollback
         ;;
      5)
         two_cfg_ensure_dirs
         two_apply_show_report
         ;;
      6|*) two_log_if INFO "退出。"; return 0;;
    esac
  done
}

main() {
  two_parse_args "$@"
  case "$TWO_CMD" in
    detect)   two_run_detect ;;
    status)   two_report_status_view ;;
    apply)
      two_run_detect >/dev/null
      two_apply_run
      ;;
    rollback) two_cfg_ensure_dirs; two_apply_rollback ;;
    report)   two_cfg_ensure_dirs; two_apply_show_report ;;
    menu)     two_run_menu ;;
  esac
}

main "$@"
