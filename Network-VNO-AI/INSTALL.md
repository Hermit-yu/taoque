# Network-VNO-AI 安装与运行（INSTALL.md）

## 1. 环境要求

- Linux（目标运行环境：VPS / 物理机 / 容器宿主机）
- bash 4+（核心逻辑纯 bash + awk）
- 建议具备（缺失则自动降级，不影响只读检测）：
  - `sysctl` / `ip` / `tc` / `ethtool` / `ss` / `ping` / `curl` / `lsmod` / `modprobe` / `systemd-detect-virt`
- 应用优化需要 **root**；仅检测无需 root
- 核心运行期**不依赖 Python**（仅测试套件用 python3 校验 JSON）

## 2. 安装

直接把整个目录放到任意位置即可（路径参数化，无需 `/opt` 固定路径）：

```bash
git clone <repo> Network-VNO-AI
cd Network-VNO-AI
chmod +x vno-ai.sh modules/*.sh modules/lib/*.sh
```

> 也可用 `VNO_HOME` 环境变量覆盖项目根；用 `PROC_ROOT/SYS_ROOT/ETC_ROOT/SYSCTL_DIR` 重定向系统根（用于测试或容器特殊挂载）。

## 3. 运行

```bash
# 交互菜单
sudo bash vno-ai.sh

# CLI 常用命令
sudo bash vno-ai.sh --all        # 完整检测 + 自适应计算（不应用）
sudo bash vno-ai.sh --apply      # 应用优化（备份→确认→应用→验证）
sudo bash vno-ai.sh --rollback   # 回滚
sudo bash vno-ai.sh --report     # 生成报告
sudo bash vno-ai.sh --monitor    # 配置漂移监控
sudo bash vno-ai.sh --benchmark  # 性能闭环
sudo bash vno-ai.sh --help       # 全部选项
```

## 4. 典型流程

1. 先以普通用户跑一遍完整检测（`--all`），看报告里"是否已合理"。
2. 若建议修改，再 `sudo bash vno-ai.sh --apply`，按提示确认。
3. 应用后用 `--benchmark` 做优化前后对比，确认收益。
4. 任何不爽，`--rollback` 一键回到应用前状态（原系统配置不受影响）。

## 5. 卸载

- 本工具只往 `/etc/sysctl.d/90-vno-ai.conf` 写一个独立文件，并保留 `backup/`。
- 卸载：执行 `--rollback`（清除自身配置并恢复备份），然后删除整个项目目录即可。
- 不会在系统其它位置留下残留。
