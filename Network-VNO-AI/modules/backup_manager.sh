#!/bin/bash
# Network-VNO-AI 阶段 5：配置备份管理（backup_manager.sh）
# 任务书第 14.3/14.4：应用前完整备份；只备份相关配置；记录清单；不覆盖原文件。
# 可被 safe_config source（提供 do_backup）；也可独立运行：bash backup_manager.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" 2>/dev/null || true

# 执行备份：拷贝 /etc/sysctl.conf、/etc/sysctl.d/*、以及本工具已存在的配置到 backup/，并写清单
do_backup() {
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    ensure_dirs
    local backup_sub="${BACKUP_DIR}/backup-${ts}"
    mkdir -p "$backup_sub"
    local manifest="${backup_sub}/manifest.json"
    local backed=()

    # 备份系统 sysctl 配置（只拷贝，不修改）
    if [[ -r "${ETC_ROOT}/sysctl.conf" ]]; then
        cp -a "${ETC_ROOT}/sysctl.conf" "${backup_sub}/sysctl.conf" 2>/dev/null && backed+=("sysctl.conf")
    fi
    if [[ -d "${SYSCTL_DIR}" ]]; then
        for f in "${SYSCTL_DIR}"/*.conf; do
            [[ -r "$f" ]] || continue
            cp -a "$f" "${backup_sub}/$(basename "$f")" 2>/dev/null && backed+=("$(basename "$f")")
        done
    fi
    # 备份当前推荐快照（便于回滚到"应用前建议"）
    [[ -r "${DATA_DIR}/recommendations.json" ]] && cp -a "${DATA_DIR}/recommendations.json" "${backup_sub}/recommendations.json" 2>/dev/null

    # 写清单（记录本次备份了哪些、时间戳、以及本工具管理的配置标识）
    {
      echo "{"
      echo "  \"timestamp\": \"$(vno_now)\","
      echo "  \"backup_dir\": \"${backup_sub}\","
      echo "  \"managed_conf\": \"${CONF_FILE}\","
      echo "  \"backed_up\": ["
      local first=1
      for b in "${backed[@]:-}"; do
        [[ -z "$b" ]] && continue
        [[ $first -eq 1 ]] && { echo "    \"$b\""; first=0; } || echo "    ,\"$b\""
      done
      echo "  ],"
      echo "  \"note\": \"仅备份 sysctl 相关配置；本工具配置统一以 90-vno-ai.conf 标识，回滚只处理本工具管理的内容\""
      echo "}"
    } > "$manifest"

    # 记录最新备份指针（供 rollback 快速定位）
    echo "$backup_sub" > "${BACKUP_DIR}/.last_backup" 2>/dev/null || true
    echo "${backup_sub}"
}

main() {
    echo "=== 配置备份管理 ==="
    echo "正在备份当前系统 sysctl 配置到 ${BACKUP_DIR}/ ..."
    local dir; dir=$(do_backup)
    echo "备份完成：${dir}"
    echo "（仅拷贝原配置，未做任何修改）"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
