# Network-VNO-AI 迁移指南（MIGRATION.md）

## 从第一版 TCP Window Optimizer 迁移

第一版（TCP Window Optimizer）的核心文件完整保留，**未被本系统修改或删除**（阶段 0 审计报告已确认）。本系统是其升级版，定位从"TCP Window 专项优化"扩展为"全维度网络诊断 + 自适应优化"。

### 区别对照

| 维度 | 第一版 | 本系统（Network-VNO-AI） |
|---|---|---|
| 检测范围 | TCP Window 为主 | 硬件/TCP/网络/拥塞控制/qdisc/网卡/MTU 全维度 |
| 计算 | 单场景 BDP | 多因素（BDP + 内存预算 + 场景 + 可信度 + 三档） |
| 优化建议 | 给出参数 | 区分"已合理不改 / 建议改"，能力门控（BBR 不万能） |
| 安全 | 有备份/回滚 | 备份 + 差异预览 + SSH 保护 + 事务式 + 自动回滚条件 |
| 性能验证 | 单次报告 | 优化前后闭环对比（benchmark） |
| 输出 | 文本报告 | 统一 JSON 契约 + 中文报告 |
| 依赖 | bash + 部分 Python | 核心零 Python（仅测试用 python3） |

### 迁移步骤

1. **保留第一版**：`/opt/TCP Window Optimizer/` 原样保留，无需迁移。
2. **部署本系统**：将 Network-VNO-AI 放到目标机任意位置（无需 `/opt`）。
3. **首次检测**：`bash vno-ai.sh --all`，确认读到的硬件/网络是真实值。
4. **审慎应用**：仅当建议修改时，才 `bash vno-ai.sh --apply`（会自动备份第一版及系统既有 sysctl）。
5. **验证收益**：`bash vno-ai.sh --benchmark` 看优化前后对比。
6. **回滚随时可用**：`bash vno-ai.sh --rollback`。

### 兼容说明

- 本系统写的是独立文件 `90-vno-ai.conf`，与第一版配置互不覆盖。
- 若第一版与本系统同时启用，以 `sysctl --system` 加载顺序中靠后的为准；建议二选一运行，避免参数互相覆盖。
- 所有数据契约在 `data/*.json`，可从第一版文本报告平滑过渡到结构化 JSON。
