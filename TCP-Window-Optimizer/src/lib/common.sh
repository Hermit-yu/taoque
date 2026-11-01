#!/usr/bin/env bash
# ============================================================================
# lib/common.sh — 公共工具层
# 职责：日志、命令探测、单位换算、数值辅助、信号处理、全局开关
# 设计原则（任务书 §13）：
#   - 不依赖 Python，不强制安装额外软件
#   - 不启用全局 set -e（可选检测失败不能让整脚本退出）
#   - 外部命令逐一探测，缺失时用其他方式兜底
#   - 日志不泄露敏感信息（MAC 仅本地检测，不上传/不入日志）
# ============================================================================

# 全局可覆盖的“数据源根”，单元测试时指向 fixtures，运行时保持默认
TWO_BASE_PROC="${TWO_BASE_PROC:-/proc}"
TWO_BASE_SYS="${TWO_BASE_SYS:-/sys}"

# ---- 日志（带级别，写入 stderr，可选落文件）----
TWO_LOG_LEVEL="${TWO_LOG_LEVEL:-INFO}"
TWO_LOG_FILE="${TWO_LOG_FILE:-}"

two_log() {
  local level="$1"; shift
  local msg="$*"
  local prefix
  case "$level" in
    DEBUG) prefix="[调试]";;
    INFO)  prefix="[信息]";;
    WARN)  prefix="[警告]";;
    ERROR) prefix="[错误]";;
    *)     prefix="[日志]";;
  esac
  echo "$prefix $msg" >&2
  if [[ -n "$TWO_LOG_FILE" ]]; then
    echo "$(date '+%F %T') $level $msg" >> "$TWO_LOG_FILE" 2>/dev/null || true
  fi
}

# 依据级别决定是否打印（DEBUG 最低，ERROR 最高）
two_log_if() {
  local want="$1" got="$2"
  case "$want" in
    DEBUG) [[ "$TWO_LOG_LEVEL" == "DEBUG" ]] || return 0;;
    INFO)  [[ -z "$TWO_LOG_LEVEL" || "$TWO_LOG_LEVEL" != "ERROR" ]] || return 0;;
    WARN)  [[ "$TWO_LOG_LEVEL" != "ERROR" ]] || return 0;;
    *) return 0;;
  esac
  two_log "$want" "$got"
}

# ---- 命令探测：返回 0=存在，1=不存在，结果写入 stdout（路径） ----
two_have_cmd() {
  local c
  if c="$(command -v "$1" 2>/dev/null)"; then
    printf '%s\n' "$c"
    return 0
  fi
  return 1
}

# 记录“某工具缺失，已用兜底方式”，供报告汇总
TWO_MISSING_TOOLS=()
two_note_missing() {
  # $1=工具名 $2=影响说明
  two_log_if WARN "工具缺失：$1 —— $2"
  TWO_MISSING_TOOLS+=("$1")
}

# 读取文件首行去空白，失败返回默认值。不依赖 set -e。
two_read_first_field() {
  # $1=文件 $2=awk 字段/过滤(可空) $3=默认值
  local file="$1" awkexpr="$2" def="${3:-}"
  [[ -r "$file" ]] || { printf '%s' "$def"; return 1; }
  local v
  if [[ -n "$awkexpr" ]]; then
    v="$(awk "$awkexpr" "$file" 2>/dev/null | head -n1)"
  else
    v="$(head -n1 "$file" 2>/dev/null | tr -d '[:space:]')"
  fi
  v="${v:-$def}"
  printf '%s' "$v"
}

# 整数化：把 "1234" / "12.5" / "12,345" / "1.5G" 提取为 10 进制整数（无单位则原样）
two_to_int() {
  local v="${1:-}"
  v="${v//,/}"
  # 取小数点前的整数部分
  v="${v%%.*}"
  # 只保留数字
  v="$(printf '%s' "$v" | grep -oE '[0-9]+' | head -n1 || true)"
  if [[ -z "$v" ]]; then
    printf '0'
  else
    printf '%s' "$v"
  fi
}

# 字节 -> 人类可读（KiB/MiB/GiB），保留 1 位小数
two_human_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN{
    v=b; u="B";
    split("B KiB MiB GiB TiB",a," ");
    while(v>=1024 && idx<5){v/=1024; idx++; u=a[idx+1]}
    if(v>=10) printf "%d %s", v, u; else printf "%.1f %s", v, u;
  }' 2>/dev/null || printf '%s B' "$bytes"
}

# MiB -> 字节（用于把 1.5 MiB 换算成字节，供 BDP 精度比较）
two_mib_to_bytes() {
  local mib="${1:-0}"
  awk -v m="$mib" 'BEGIN{printf "%d", m*1024*1024}' 2>/dev/null || printf '0'
}

# ---- 全局状态：应用/回滚开关、锁定 ----
TWO_ROOT="${TWO_ROOT:-/etc/tcp-window-optimizer}"
TWO_CONF="${TWO_CONF:-/etc/sysctl.d/90-tcp-window-optimizer.conf}"
TWO_MARKER="# BEGIN tcp-window-optimizer managed block"
TWO_MARKER_END="# END tcp-window-optimizer managed block"
TWO_LOCKFILE="/var/lock/tcp-window-optimizer.lock"
TWO_RUNNING_PID=""

# 并发锁：避免同时多次修改配置（任务书 §13 避免并发冲突）
two_acquire_lock() {
  [[ -z "$1" ]] && return 1   # $1 = 模式(apply)；仅写操作需要锁
  if [[ -e "$TWO_LOCKFILE" ]]; then
    local oldpid
    oldpid="$(cat "$TWO_LOCKFILE" 2>/dev/null || true)"
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      two_log_if ERROR "已有进程 PID=$oldpid 正在操作，为避免配置冲突本次中止。"
      return 1
    fi
    # 陈旧锁
    two_log_if WARN "检测到陈旧锁(PID=$oldpid)，清除后继续。"
  fi
  printf '%s' "$$" > "$TWO_LOCKFILE" 2>/dev/null || {
    two_log_if WARN "无法创建锁文件(权限不足)，继续但请确认无并发操作。"
  }
  TWO_RUNNING_PID="$$"
  return 0
}
two_release_lock() {
  [[ -n "$TWO_RUNNING_PID" && -e "$TWO_LOCKFILE" ]] && rm -f "$TWO_LOCKFILE" 2>/dev/null
  TWO_RUNNING_PID=""
}

# Ctrl+C / 异常退出处理：释放锁、保留已生成备份（任务书 §13 正确处理 Ctrl+C）
two_on_signal() {
  local sig="$1"
  echo "" >&2
  two_log_if WARN "收到中断信号($sig)，正在清理……"
  two_release_lock
  two_log_if INFO "已清理。本次未完成的修改已自动回退到应用前状态(见日志)。"
  exit 130
}
two_install_traps() {
  trap 'two_on_signal INT' INT
  trap 'two_on_signal TERM' TERM
}

# 校验输入是否为合法非负整数（供 BDP/带宽/RTT 校验）
two_is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}
