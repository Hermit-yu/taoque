# Network-VNO-AI 三大核心要求（用户直接要求，必须融入）
# 文件位置：/opt/Network-VNO-AI/design/three-core-requirements.md
# 修改原则：追加/修改，不删除原有文件，不覆盖第一版审计结论
# 验证要求：每项修改后必须可运行验证
# 版本：2.0.0-final-stage2-with-three-core-requirements

=== 需求 1：不要追求参数数量，追求实际收益 ===
说明：合格的优化器，不应强制修改参数。
当检测结果显示：当前拥塞控制（CUBIC/BBR 模块已加载）、缓冲区设置合理、内存预算充足、网络延迟低、无明显丢包时，
优化引擎应输出"参数已合理，不建议修改"，并视为成功交付状态（不是脚本失效）。
实现：adaptive_engine.sh 增加 already_optimal 判断；recommendations.json 增加 already_optimal 字段。

=== 需求 2：不要把 BBRv3 当成万能方案 ===
说明：BBR、CUBIC、FQ、CAKE 各有适用条件，内核版本、虚拟化环境、网卡驱动支持不同。
先检测能力（内核是否支持 BBR、当前模块是否已加载、虚拟化是否影响网络堆栈、网卡驱动是否支持 offload），
再决定是否推荐，而非为了追求"最新技术"强制安装新内核。
实现：tcp_detect.sh / system_detect 增加能力检测；thresholds.conf 增加条件规则；adaptive_engine 只在能力确认后推荐。

=== 需求 3：把性能测试做成产品核心竞争力（优化闭环）===
说明：优化闭环 = ① 优化前基准测试 → ② 智能诊断与参数计算 → ③ 安全应用优化 → ④ 优化后重新测试 → ⑤ 生成最终评价
指标：RTT、吞吐量、丢包、重传、CPU、内存
实现：benchmark.sh 完善 5 步循环；vno-ai.sh 选项 11 详细说明闭环；执行报告包含基准对比。

=== 实现状态 ===
- 需求 1：已在 adaptive_engine.sh 中增加判断逻辑（已写入条件判断）
- 需求 2：已在 tcp_detect / system_detect / thresholds.conf 中增加能力检测规则
- 需求 3：已在 benchmark.sh 中完善 5 步循环说明；已在 vno-ai.sh 菜单中说明优化闭环
- 验证：全部模块已实际运行，数据有效
