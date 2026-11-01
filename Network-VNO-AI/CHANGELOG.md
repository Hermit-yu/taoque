# 变更记录（CHANGELOG.md）

## v2.3.0 (交互清晰化)
- **新增 `modules/status_panel.sh`（实际应用状态面板）**：真实读取 `/etc/sysctl.d/90-vno-ai.conf` 目标值与 `/proc/sys` 生效值逐项对比，用 `✓ 已生效 / ⚠ 未生效 / ○ 未应用` 明确标识每项调优的实际状态；同时列出 14 个模块的可用性与数据新鲜度（24h）、优化建议档位/置信度、备份快照数，并**根据当前实际状态**给出下一步指引。
- **主入口改造（`vno-ai.sh`）**：菜单启动即显示「当前实际状态」速览行；新增 `[17]` 查看状态面板；`--status` 从裸 `ls` 升级为真面板；新增 `--panel`（别名）与 `--status-compact`（单行速览，供巡检/脚本调用）；`export VNO_HOME` 使子模块与 mock 重定向一致。
- **修复真实 bug**：`apply_state` 初版按字节比对 `tcp_rmem` 等多值参数，因 `/proc` 用制表符、conf 用空格而误判「未生效」；改为空白归一化后精确比对。
- **测试**：`tests/run_tests.sh` 新增第 6 节状态面板 5 条断言（未应用 / 已生效 / 不误报 / 漂移 / compact），**53 通过 / 0 失败**（本地 + B 机真机均 53/0）。
- **文档**：README 增补状态面板能力、`--status` 用法与目录项。

## v2.2.0 (本次交付)
- **架构重构**：引入 `modules/lib/common.sh` 共享库，路径全部参数化（`VNO_HOME / PROC_ROOT / SYS_ROOT / ETC_ROOT / SYSCTL_DIR` 可重定向），使检测逻辑可用 mock 的 `/proc /sys /etc` 验证，核心零 Python 依赖。
- **统一 JSON 契约**：所有模块输出结构化 JSON 到 `data/`，模块间只靠 JSON 解耦。
- **新增/重写模块**：
  - 检测：`system_detect.sh`、`tcp_detect.sh`（修复 sockstat/snmp 解析 bug）、`network_quality.sh`、`network_detect.sh`（异常分析）、`congestion_control.sh`、`qdisc_manager.sh`、`nic_optimizer.sh`、`mtu_mss.sh`。
  - 测速：`bandwidth_test.sh`（默认允许测速、先明示流量）、`bufferbloat_test.sh`。
  - 计算与应用：`adaptive_engine.sh`（已合理判定 + 能力门控 + 三档决策）、`tcp_optimizer.sh`（真实 BDP/内存预算计算，可单测）、`safe_config.sh`（事务式安全应用/回滚）、`backup_manager.sh`、`rollback_manager.sh`。
  - 报告与验证：`report_engine.sh`（**从真实 JSON 读取，禁伪造**）、`benchmark.sh`（真实优化前后闭环）、`monitor.sh`（配置漂移/历史/重算）。
- **主入口**：重写 `vno-ai.sh`，提供 16 项中文菜单 `[1]-[16]` + 完整 CLI，统一调用上述模块。
- **测试**：新增 `tests/run_tests.sh`（bash -n + 计算单测 + mock 冒烟 + JSON 合法性），当前 38 项用例全通过。
- **文档**：补齐 README / DESIGN / ALGORITHM / SAFETY / INSTALL / MIGRATION / TEST-REPORT / CHANGELOG。
- **三大核心要求落地**：①已合理则不改 ②BBR 能力门控不盲目 ③性能闭环验证收益。

## v2.0.0-final-stage2 (历史)
- 引入三大核心要求文档 `design/three-core-requirements.md`。

## v2.0.0-final-stage1 (历史)
- 阶段 0 审计：确认第一版 TCP Window Optimizer 完整保留，未修改、未删除。

## 第一版（TCP Window Optimizer）
- 单脚本 + 9 模块，专注 TCP Window 深度优化；已完成自身测试（10/10）。
- 作为上游基础，完整保留。
