#!/bin/bash
# Network-VNO-AI 阶段 5：配置回滚管理（rollback_manager.sh）
# 任务书第 14.6：只回滚本工具实际管理的配置（90-vno-ai.conf），恢复被备份的原系统配置；绝不删除用户自己的配置。
# 可被 safe_config source（提供 do_rollback）；也可独立运行：bash rollback_manager.sh [事务ID/时间戳]

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" 2>/dev/null || true

# 定位备份目录：优先参数指定，否则用最近一次备份指针
_find_backup_dir() {
    local specified="${1:-}"
    if [[ -n "$specified" && -d "$specified" ]]; then echo "$specified"; return; fi
    [[ -r "${BACKUP_DIR}/.last_backup" ]] && cat "${BACKUP_DIR}/.last_backup" && return
    # 回退：找最新的 backup-*
    ls -1dt "${BACKUP_DIR}"/backup-* 2>/dev/null | head -1
}

do_rollback() {
    local specified="${1:-}"
    local bdir; bdir=$(_find_backup_dir "$specified")
    if [[ -z "$bdir" || ! -d "$bdir" ]]; then
        echo "无法回滚：未找到任何备份（请确认是否已执行过备份）" >&2
        return 1
    fi
    echo "使用备份：${bdir}"

    # 1) 删除本工具生成的配置（只删我们自己的）
    if [[ -f "$CONF_FILE" ]]; then
        rm -f "$CONF_FILE" 2>/dev/null && echo "已删除本工具配置：${CONF_FILE}"
    else
        echo "本工具配置不存在，无需删除"
    fi

    # 2) 恢复被备份的原系统配置（若本次备份里有对应原文件，则还原，避免误删用户配置）
    [[ -r "${bdir}/sysctl.conf" && -w "${ETC_ROOT}/sysctl.conf" ]] && cp -a "${bdir}/sysctl.conf" "${ETC_ROOT}/sysctl.conf" 2>/dev/null && echo "已恢复原 /etc/sysctl.conf"
    if [[ -d "$bdir" ]]; then
        for f in "${bdir}"/*.conf; do
            [[ -r "$f" ]] || continue
            local name; name="$(basename "$f")"
            [[ "$name" == "90-vno-ai.conf" ]] && continue   # 本工具自己的配置不恢复
            [[ -d "${SYSCTL_DIR}" ]] && cp -a "$f" "${SYSCTL_DIR}/${name}" 2>/dev/null && echo "已恢复原系统配置：${name}"
        done
    fi

    # 3) 若内核已加载，尝试重新应用被恢复的配置（可选，需 root；非强制）
    if is_root && have_cmd sysctl; then
        sysctl --system >/dev/null 2>&1 && echo "已重新加载系统 sysctl 配置" || echo "重新加载 sysctl 失败（不影响回滚结果）"
    fi
    echo "回滚完成：仅处理本工具管理的配置，用户原有配置未被删除。"
    return 0
}

main() {
    echo "=== 配置回滚管理 ==="
    do_rollback "${1:-}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
