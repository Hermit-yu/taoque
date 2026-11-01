# Network-VNO-AI

全维度网络智能诊断与自适应优化系统（第二代，基于 TCP Window Optimizer 升级）。

一句话定位：**把"改参数"这件事做成一套真实可验证的工程**——先真实探测硬件、TCP、网络，再用真实数学算出建议，应用前必备份、必确认、可回滚，最后用优化前后实测对比证明"优化到底有没有用"。

> 设计铁律：**检测/计算/优化必须真实，绝不写死常量或伪造数值**；核心运行期零 Python 依赖（仅测试用 python3 校验 JSON）。

## 它能做什么

| 能力 | 模块 | 说明 |
|---|---|---|
| 硬件检测 | `system_detect.sh` | CPU/内存/网卡/虚拟化/NUMA/拓扑/负载/Steal |
| TCP 深度诊断 | `tcp_detect.sh` | Window 参数、拥塞控制（BBR 实际注册/模块加载）、连接状态、重传/丢包 |
| 网络质量 | `network_quality.sh` | 多目标 RTT、抖动、丢包、p50/p95（ICMP，非 TCP 实测） |
| 网络异常分析 | `network_detect.sh` | 结合 Steal/重传/网卡丢包/TIME_WAIT 综合判定 |
| 带宽实测 | `bandwidth_test.sh` | 默认允许测速，但**先明示预计流量与时长**；支持 curl/iperf3/用户指定 |
| Bufferbloat | `bufferbloat_test.sh` | 空闲/负载 RTT 增量检测 |
| 拥塞控制能力 | `congestion_control.sh` | BBR 能力门控（需求2：不把 BBR 当万能） |
| 队列(qdisc) | `qdisc_manager.sh` | 当前 qdisc 识别 + 业务场景建议 |
| 网卡调优 | `nic_optimizer.sh` | RSS/RPS/IRQ/Offload/队列诊断（默认只读） |
| MTU/MSS | `mtu_mss.sh` | 路径 MTU 与 MSS 合理性 |
| 自适应计算 | `adaptive_engine.sh` | 多因素 BDP/内存预算/三档决策/需求1（已合理则不改） |
| 安全应用 | `safe_config.sh` | 备份→差异预览→确认→独立配置→验证；支持回滚 |
| 性能闭环 | `benchmark.sh` | 基准→应用→复测→评价（优化到底有没有用） |
| 报告 | `report_engine.sh` | 全部从真实 JSON 汇总，绝不伪造 |
| 监控 | `monitor.sh` | 配置漂移/历史/重算建议（只读） |
| 状态面板 | `status_panel.sh` | **真实标识**每项功能是否可用/已检测、优化是否已生效（对照 `/proc/sys` 实际值）、未生效漂移与下一步指引 |

## 快速开始

```bash
# 交互菜单（中文，17 个功能项 + 退出；启动即显示当前实际状态速览）
sudo bash vno-ai.sh

# 一眼看清"哪些已生效、哪些没应用"（真实读 /proc/sys 对比）
sudo bash vno-ai.sh --status

# 或者直接用 CLI
sudo bash vno-ai.sh --all        # 完整检测 + 计算（不含应用）
sudo bash vno-ai.sh --report     # 生成完整报告
sudo bash vno-ai.sh --apply      # 应用优化（会先备份并要求确认）
sudo bash vno-ai.sh --rollback   # 回滚
sudo bash vno-ai.sh --benchmark  # 性能基准闭环
sudo bash vno-ai.sh --help       # 查看全部选项
```

> 应用/回滚需要 root；检测类默认只读，普通用户也能跑。

## 目录结构

```
Network-VNO-AI/
├── vno-ai.sh                 # 主入口（菜单 + CLI）
├── VERSION                   # 版本号
├── modules/
│   ├── lib/common.sh         # 共享库：路径参数化、依赖探测、JSON 辅助、大白话日志
│   ├── system_detect.sh      # 硬件检测
│   ├── tcp_detect.sh         # TCP/IP 深度诊断
│   ├── network_quality.sh    # 网络质量测量
│   ├── network_detect.sh     # 网络异常分析
│   ├── bandwidth_test.sh     # 带宽实测（默认允许测速）
│   ├── bufferbloat_test.sh   # Bufferbloat 检测
│   ├── congestion_control.sh  # 拥塞控制能力门控
│   ├── qdisc_manager.sh      # 队列诊断
│   ├── nic_optimizer.sh       # 网卡诊断
│   ├── mtu_mss.sh            # MTU/MSS 检测
│   ├── adaptive_engine.sh     # 自适应计算引擎
│   ├── safe_config.sh         # 安全应用与回滚
│   ├── backup_manager.sh      # 备份
│   ├── rollback_manager.sh     # 回滚
│   ├── report_engine.sh       # 报告引擎
│   ├── benchmark.sh           # 性能闭环
│   ├── monitor.sh             # 长期监控
│   └── status_panel.sh        # 实际应用状态面板（已生效/未生效/未应用真实标识）
├── data/                     # 统一 JSON 输出（运行时生成）
├── backup/                   # 应用前自动备份
├── reports/                  # 生成的报告
├── config/                   # 配置文件（可选）
└── tests/run_tests.sh        # 测试套件
```

## 三大核心要求（来自用户）

1. **追求实际收益，不追求参数数量**：检测显示已合理（窗口缩放/自动调节已开、缓冲区充足、低延迟、无异常）时，输出"已合理，不建议修改"并视为成功交付。
2. **BBR 不是万能**：先检测能力（内核是否注册 BBR、模块是否加载、虚拟化是否受限、网卡驱动是否支持），再决定是否推荐，绝不为追新强制升级内核。
3. **性能测试做成核心竞争力**：优化闭环 = 优化前基准 → 诊断与计算 → 安全应用 → 优化后复测 → 生成评价，用真实前后数据证明收益。

## 文档

- [DESIGN.md](DESIGN.md) 架构与设计原则
- [ALGORITHM.md](ALGORITHM.md) BDP、内存预算、三档决策算法
- [SAFETY.md](SAFETY.md) 安全机制与操作边界
- [INSTALL.md](INSTALL.md) 安装与运行
- [MIGRATION.md](MIGRATION.md) 从第一版（TCP Window Optimizer）迁移
- [TEST-REPORT.md](TEST-REPORT.md) 测试与验证
- [CHANGELOG.md](CHANGELOG.md) 变更记录
