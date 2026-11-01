#!/bin/bash
# Network-VNO-AI 共享库（lib/common.sh）
# 设计目标：
#   1. 路径参数化 —— 项目根 VNO_HOME 默认取脚本所在项目根，可由环境变量覆盖（便于测试/重定位安装）。
#   2. 系统根可重定向 —— PROC_ROOT/SYS_ROOT/ETC_ROOT/SYSCTL_DIR 可重定向，使检测模块能在测试环境中用 mock 的 /proc、/sys、/etc 验证。
#   3. 依赖逐项探测 —— 缺失命令优雅降级，绝不因某个工具缺失而崩溃。
#   4. 核心零 Python 依赖 —— 仅用 bash + awk + 标准工具；JSON 解析用 grep/sed，写入用 heredoc。
#   5. 大白话日志 —— 所有面向用户提示均为中文自然语言，无机器文（TCP_ / %s / key=value 等）。
#
# 使用方法：每个模块在开头 source 本文件：
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ---------- 0. 基础防护 ----------
# 不全局 set -e（避免可选检测失败导致整个程序退出）；各模块自行处理关键错误。
set -u

# ---------- 1. 项目根与目录 ----------
_resolve_link() {
    local src="$1" link
    while [[ -L "$src" ]]; do
        link="$(readlink "$src" 2>/dev/null || echo "")"
        [[ -z "$link" ]] && break
        [[ "$link" == /* ]] && src="$link" || src="$(dirname "$src")/$link"
    done
    echo "$src"
}

if [[ -z "${VNO_HOME:-}" ]]; then
    _common_src="$(_resolve_link "${BASH_SOURCE[0]}")"
    VNO_HOME="$(cd "$(dirname "$_common_src")/../.." && pwd)"
fi
export VNO_HOME

DATA_DIR="${VNO_HOME}/data"
CONFIG_DIR="${VNO_HOME}/config"
BACKUP_DIR="${VNO_HOME}/backup"
REPORTS_DIR="${VNO_HOME}/reports"
LOGS_DIR="${VNO_HOME}/logs"
MODULES_DIR="${VNO_HOME}/modules"
HISTORY_DIR="${DATA_DIR}/history"

# 系统根（测试可重定向）
PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"
ETC_ROOT="${ETC_ROOT:-/etc}"
SYSCTL_DIR="${SYSCTL_DIR:-${ETC_ROOT}/sysctl.d}"
CONF_FILE="${SYSCTL_DIR}/90-vno-ai.conf"

# ---------- 2. 通用辅助 ----------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 大白话日志：带模块名与层级（INFO/WARN/ERR）
vno_log() {
    local level="${1:-INFO}"; shift 2>/dev/null || true
    local msg="$*"
    case "$level" in
        WARN) echo "  [提示] ${msg}" ;;
        ERR)  echo "  [注意] ${msg}" ;;
        *)    echo "  ${msg}" ;;
    esac
}

# 安全读取 sysctl 值：优先读 /proc/sys（mock 友好），失败回退 sysctl 命令
read_sysctl() {
    local k="$1"
    local proc_path="${PROC_ROOT}/sys/${k//./\/}"
    if [[ -r "$proc_path" ]]; then
        local v
        v="$(cat "$proc_path" 2>/dev/null)"
        [[ -n "$v" ]] && { echo "$v"; return 0; }
    fi
    if have_cmd sysctl; then
        sysctl -n "$k" 2>/dev/null
        return 0
    fi
    echo ""
}

# 安全读取 /sys 文件，缺失返回空
read_sys() {
    local p="$1"
    [[ -r "$p" ]] && cat "$p" 2>/dev/null || echo ""
}

# 读取 ini 风格配置（profiles.conf / thresholds.conf）的某个 key 的值
# 用法：read_conf_value <file> <section> <key>
read_conf_value() {
    local file="$1" section="$2" key="$3"
    [[ -r "$file" ]] || { echo ""; return; }
    awk -v sec="[$section]" -v k="$key" '
        $0==sec {f=1; next}
        /^\[/ {f=0}
        f && index($0,k"=")==1 {sub(/^[^=]*=/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}
    ' "$file"
}

# 从 JSON 文件提取首个匹配 key 的字符串值（核心无 python 依赖）
# 用法：get_json_field <file> <key>
get_json_field() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || { echo ""; return; }
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$file" 2>/dev/null | head -1
}

# 从 JSON 文件提取首个匹配 key 的数值（去掉单位/空格）
get_json_number() {
    local file="$1" key="$2"
    local v
    v="$(get_json_field "$file" "$key")"
    v="${v//[^0-9.]/}"
    echo "${v:-0}"
}

# 清理字符串中的控制字符（避免写 JSON 时产生非法字符）
sanitize_json() {
    local s="$1"
    # 去掉换行/回车/Tab/其他控制字符，转义双引号与反斜杠
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s" | tr -d '\n\r\t\v\f' | sed 's/  */ /g'
}

# 确保目录存在
ensure_dirs() {
    mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$REPORTS_DIR" "$LOGS_DIR" "$HISTORY_DIR" 2>/dev/null || true
}

# 时间戳（兼容无 date -Iseconds 的旧系统）
vno_now() {
    date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S
}

# 检查当前是否为远程 SSH 会话（用于安全保护）
is_ssh_session() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

# 检查是否 root
is_root() { [[ $EUID -eq 0 ]]; }

# 导出关键变量供子模块使用
export DATA_DIR CONFIG_DIR BACKUP_DIR REPORTS_DIR LOGS_DIR MODULES_DIR HISTORY_DIR \
       PROC_ROOT SYS_ROOT ETC_ROOT SYSCTL_DIR CONF_FILE
