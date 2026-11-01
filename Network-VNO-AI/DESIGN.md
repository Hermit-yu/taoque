# Network-VNO-AI 设计文档（DESIGN.md）

## 1. 设计目标

把"网络优化"从"凭经验改几个 sysctl"升级为一套**可验证的工程**：

- **真实优先**：一切数值来自真实探测与真实计算，绝不明文写死常量，绝不伪造硬件/带宽/结论。
- **失败不崩溃**：每个模块独立运行，单项检测失败不影响整体；依赖命令缺失时优雅降级。
- **默认只读**：除用户显式"应用"外，所有模块不修改系统。
- **核心零 Python 依赖**：运行期只用 bash + awk + 标准工具；仅测试用 python3 校验 JSON。

## 2. 整体架构

```
vno-ai.sh（主入口）
   │  解析项目根、分发菜单/CLI
   ▼
modules/*（各功能模块，各自 source lib/common.sh）
   │  检测 → 计算 → 建议 →（用户确认后）应用
   ▼
data/*.json（统一数据结构，模块间唯一契约）
   ▼
safe_config.sh（事务式安全应用：备份 → 预览 → 确认 → 写独立文件 → 验证 → 可回滚）
```

### 关键设计：路径参数化与可测试性

`lib/common.sh` 将项目根 `VNO_HOME` 解析为脚本所在项目根（可用环境变量覆盖）；系统根 `PROC_ROOT / SYS_ROOT / ETC_ROOT / SYSCTL_DIR` 可重定向。这意味着**检测逻辑可以在测试环境用 mock 的 `/proc /sys /etc` 验证**，无需真实 Linux 内核——这正是本项目能在 Windows/Cygwin 开发、目标在 Linux VPS 上交付的原因。

### 关键设计：统一 JSON 契约

所有模块输出结构化 JSON 到 `data/`，模块之间只靠 JSON 传递数据，互不耦合。例如 `adaptive_engine.sh` 只读 `hardware.json / network_quality.json / tcp_detect_result.json / bandwidth.json`，并产生 `recommendations.json`；`safe_config.sh` 再读 `recommendations.json`（经 `recommendations.sh` 桥接）生成真实配置。

## 3. 模块职责边界

| 模块 | 职责 | 是否修改系统 |
|---|---|---|
| system_detect | 硬件全量探测 | 否 |
| tcp_detect | TCP/IP 深度诊断 | 否 |
| network_quality | RTT/丢包/抖动多目标测量 | 否 |
| network_detect | 网络异常关联分析 | 否 |
| bandwidth_test | 真实带宽采样（默认允许，先明示流量） | 否（仅测速） |
| bufferbloat_test | 负载下 RTT 增量 | 否（制造短期下载负载） |
| congestion_control | BBR 等能力门控评估 | 否 |
| qdisc_manager | 队列诊断与建议 | 否 |
| nic_optimizer | 网卡 RSS/RPS/IRQ/Offload 诊断 | 否 |
| mtu_mss | MTU/MSS 路径合理性 | 否 |
| adaptive_engine | 多因素计算 → 优化建议 | 否 |
| safe_config | 应用/回滚（用户确认后） | **是（受控）** |
| report_engine | 汇总报告（从真实 JSON 读） | 否 |
| benchmark | 优化前后闭环对比 | 否（调用 safe_config 时才可能改） |
| monitor | 配置漂移/历史/重算 | 否 |

## 4. 三大核心要求的落地

1. **已合理则不改**：`adaptive_engine.sh` 计算 `already_optimal`，当 rmem_max ≥ 1.5×BDP、窗口缩放/自动调节已开、内存充足、RTT 低、无异常、Steal 低时，输出"已合理，不建议修改"。
2. **BBR 能力门控**：`congestion_control.sh` 检测 BBR 是否真的注册（available 列表）、模块是否加载、虚拟化是否受限、内核版本是否 ≥4.9；只有"非受限虚拟化 +（高 RTT 或 高带宽）+ 已注册"才建议评估切换，且需单独确认。
3. **性能闭环**：`benchmark.sh` 用 `--baseline`/`--post`/`--evaluate`（或 `--full`）采集优化前后 RTT/带宽/重传，给出"有效/退化/不显著"的真实评价，无收益则建议保留现状或回滚。

## 5. 扩展方式

新增检测项只需：新建 `modules/xxx.sh`，`source lib/common.sh`，遵循"读 `PROC_ROOT/SYS_ROOT` → 计算 → 写 `data/xxx.json`"范式，并在 `vno-ai.sh` 菜单与 CLI 加一行 `run_mod xxx.sh`。无全局状态、无硬编码路径，天然可测。
