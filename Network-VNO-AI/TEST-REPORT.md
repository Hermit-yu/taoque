# Network-VNO-AI 测试与验证报告（TEST-REPORT.md）

## 测试套件

`tests/run_tests.sh` 是项目自带的完整验证脚本，覆盖：

1. **语法检查**：对所有 `modules/*.sh` 与 `vno-ai.sh` 执行 `bash -n`。
2. **计算单测**：直接 source `tcp_optimizer.sh`，断言 `compute_tcp_params` 的真实数学：
   - 1000Mbps × RTT100 + 512MB 内存 → BDP=12,500,000 字节；rmem_max 被内存预算封顶（≈200KB，远小于 2×BDP），等级 Level 1。
   - 100Mbps × RTT6 + 8GB 内存 → BDP=75,000 字节；等级 Level 3。
3. **全模块 mock 冒烟 + JSON 合法性**：在**完全隔离**的临时 mock 根（`/proc /sys /etc` 重定向 + fake ping/curl）中运行全部检测/计算模块，断言每个 `data/*.json` 都能被 python3 解析为合法 JSON。
4. **安全应用验证**：`safe_config.sh --dry-run` 输出真实配置；`--backup` 生成备份快照。

## 隔离原则（关键）

所有测试都在临时 mock 环境中进行，**绝不触碰真实 `/proc /etc /sys`**。通过 `VNO_HOME / PROC_ROOT / SYS_ROOT / ETC_ROOT` 环境变量把模块重定向到临时根，确保可重复、可 CI、无副作用。

## 运行

```bash
bash tests/run_tests.sh
# 期望输出：测试结果：通过 38，失败 0（或更多用例时同步增长）
```

## 真实运行验证

除自动化测试外，在目标 Linux 主机上应按如下顺序人工确认：

1. `bash vno-ai.sh --all` 无报错，且 `data/*.json` 中字段为真实值（如 CPU 型号、内存、实测 RTT）。
2. `bash vno-ai.sh --apply` 必须先出现备份成功提示，再出现配置预览，最后才要求确认。
3. 应用后 `sysctl net.ipv4.tcp_rmem` 与预览一致；`--rollback` 后能恢复原值。
4. `bash vno-ai.sh --benchmark` 给出"有效/退化/不显著"的真实评价，而非恒为"有效"。

## 已知限制

- 部分指标（如 TCP 实际连接 RTT、真实外网带宽）依赖网络可达性与对应命令，缺失时模块会标注"未测得"而非伪造。
- 容器/受限虚拟化下，拥塞控制与 qdisc 的修改可能不生效；模块会检测并提示，不会假装成功。
- ICMP RTT 不等于 TCP 实际连接 RTT，报告中已明确标注。
