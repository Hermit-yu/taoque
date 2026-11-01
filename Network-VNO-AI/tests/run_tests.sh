#!/bin/bash
# Network-VNO-AI 测试套件（tests/run_tests.sh）
# 完全隔离：所有检测/写入都重定向到临时 mock 根，绝不触碰真实 /proc /etc /sys。
# 覆盖：① bash -n 语法 ② tcp_optimizer 单测（真实数学）③ 全模块 mock 冒烟 + JSON 合法性 ④ safe_config 干跑/备份
# 核心零 Python：仅用 python3 做 JSON 合法性校验（与运行期零依赖不冲突）。

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VNO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODS="$VNO_ROOT/modules"

PASS=0; FAIL=0
ok()   { echo "  [通过] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [失败] $1"; FAIL=$((FAIL+1)); }

# ---------- 1. 语法检查 ----------
echo "=== 1. bash -n 语法检查 ==="
for f in "$VNO_ROOT/vno-ai.sh" "$MODS"/*.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") 语法错误"; fi
done

# ---------- 构建隔离 mock 环境 ----------
# 注意：必须用项目内的 POSIX 路径（同一盘符），否则 Windows 版 python3 无法解析 /tmp/... 这类 Git-Bash 路径
MOCK="$VNO_ROOT/.test-tmp"
rm -rf "$MOCK"
mkdir -p "$MOCK"
MOCK_P="$MOCK"
mkdir -p "$MOCK_P/proc/sys/kernel" "$MOCK_P/proc/sys/net/ipv4" "$MOCK_P/proc/sys/net/core" \
         "$MOCK_P/proc/net" "$MOCK_P/proc" "$MOCK_P/sys/class/net/eth0/queues/rx-0" \
         "$MOCK_P/sys/class/net/eth0/queues/tx-0" "$MOCK_P/sys/class/net/lo/queues/rx-0" \
         "$MOCK_P/etc/sysctl.d" "$MOCK_P/etc" "$MOCK_P/bin" "$MOCK_P/data" "$MOCK_P/backup"
# 让 VNO_HOME 指向 mock，使 data/backup/config/reports 全部隔离
export VNO_HOME="$MOCK_P"
export PROC_ROOT="$MOCK_P/proc" SYS_ROOT="$MOCK_P/sys" ETC_ROOT="$MOCK_P/etc"

# 写 /proc/sys 模拟值
psys() { mkdir -p "$(dirname "$MOCK_P/proc/sys/$1")"; printf '%s' "$2" > "$MOCK_P/proc/sys/$1"; }
psys kernel/osrelease "5.15.0-test"
psys net/ipv4/tcp_window_scaling 1
psys net/ipv4/tcp_rmem "4096 87380 6291456"
psys net/ipv4/tcp_wmem "4096 16384 4194304"
psys net/core/rmem_max 212992
psys net/core/wmem_max 212992
psys net/core/rmem_default 212992
psys net/core/wmem_default 212992
psys net/ipv4/tcp_moderate_rcvbuf 1
psys net/ipv4/tcp_sack 1
psys net/ipv4/tcp_timestamps 1
psys net/ipv4/tcp_fastopen 1
psys net/ipv4/tcp_mtu_probing 0
psys net/ipv4/tcp_no_metrics_save 0
psys net/ipv4/tcp_autocorking 0
psys net/ipv4/tcp_limit_output_bytes 262144
psys net/ipv4/tcp_adv_win_scale 1
psys net/ipv4/tcp_app_win 0
psys net/ipv4/tcp_mem "92352 123136 184704"
psys net/ipv4/tcp_congestion_control cubic
psys net/ipv4/tcp_available_congestion_control "cubic bbr reno"
psys net/core/default_qdisc fq_codel
psys kernel/hostname testhost

# 写 /proc/net 统计
cat > "$MOCK_P/proc/net/sockstat" <<'EOF'
sockets: used 200
TCP: inuse 11 orphan 0 tw 30 alloc 23 mem 2
UDP: inuse 5 mem 1
EOF
cat > "$MOCK_P/proc/net/snmp" <<'EOF'
Ip: Forwarding 1
Tcp: RtoAlgorithm 1 RtoMin 200 RtoMax 120000 MaxConn 65535 ActiveOpens 100 passiveOpens 50 AttemptFails 2 EstabResets 1 CurrEstab 100 InErr 0 OutRsts 0 RetransSegs 500 InSegs 100000 OutSegs 99000
EOF
cat > "$MOCK_P/proc/net/netstat" <<'EOF'
TcpExt: SyncookiesSent 0 ListenOverflows 2 ListenDrops 1 TCPMemoryPressures 0
EOF
printf '' > "$MOCK_P/proc/modules"   # 不含 tcp_bbr（模拟未加载）

# 写 /proc 基础文件（system_detect 用）
cat > "$MOCK_P/proc/cpuinfo" <<'EOF'
processor : 0
model name : TestCPU Xeon
physical id : 0
cpu cores : 2
processor : 1
model name : TestCPU Xeon
physical id : 0
cpu cores : 2
EOF
cat > "$MOCK_P/proc/meminfo" <<'EOF'
MemTotal:        2048000 kB
MemAvailable:    1500000 kB
Buffers:           50000 kB
Cached:           300000 kB
SwapTotal:       1000000 kB
EOF
echo "0.00 0.01 0.05 1/234 1" > "$MOCK_P/proc/loadavg"
echo "cpu  100 0 50 1000 0 0 30 0" > "$MOCK_P/proc/stat"
echo "12345.67 9876.54" > "$MOCK_P/proc/uptime"
echo "PRETTY_NAME=TestLinux 1.0" > "$MOCK_P/etc/os-release"

# 写 /sys/class/net
for ifc in eth0 lo; do
  echo "1500" > "$MOCK_P/sys/class/net/$ifc/mtu"
  echo "up" > "$MOCK_P/sys/class/net/$ifc/operstate"
  echo "1" > "$MOCK_P/sys/class/net/$ifc/carrier"
  echo "1000" > "$MOCK_P/sys/class/net/$ifc/speed"
  echo "00000000" > "$MOCK_P/sys/class/net/$ifc/queues/rx-0/rps_cpus"
done
echo "loopback" > "$MOCK_P/sys/class/net/lo/operstate"
echo "unknown" > "$MOCK_P/sys/class/net/lo/speed"

# 写 fake ping / curl（覆盖 Windows ping.exe 对 -c/-W 的不兼容）
cat > "$MOCK_P/bin/ping" <<'EOF'
#!/bin/bash
c=5; while [ $# -gt 0 ]; do case "$1" in -c) c=$2; shift 2;; -6) shift;; -W) shift 2;; -*) shift;; *) host=$1; shift;; esac; done
echo "PING $host (1.2.3.4) 56 bytes"
i=1; while [ $i -le $c ]; do t=$(awk "BEGIN{printf \"%.1f\", 10+(i%3)}" i=$i); echo "64 bytes from $host: icmp_seq=$i ttl=57 time=${t} ms"; i=$((i+1)); done
echo "--- $host ping stats ---"; echo "$c packets, 0% packet loss, time 9012ms"
echo "rtt min/avg/max/mdev = 10.000/11.500/13.000/1.200 ms"
EOF
cat > "$MOCK_P/bin/curl" <<'EOF'
#!/bin/bash
fmt=""; while [ $# -gt 0 ]; do case "$1" in -w) fmt=$2; shift 2;; -o) shift 2;; -T) shift 2;; --max-time) shift 2;; -s) shift;; *) shift;; esac; done
case "$fmt" in *size_download*) echo "25000000";; *size_upload*) echo "8000000";; esac
EOF
chmod +x "$MOCK_P/bin/ping" "$MOCK_P/bin/curl"
export PATH="$MOCK_P/bin:$PATH"

# ---------- 2. tcp_optimizer 单测（真实数学） ----------
echo ""
echo "=== 2. tcp_optimizer 单测 ==="
source "$MODS/lib/common.sh"
source "$MODS/tcp_optimizer.sh"

# 用例A：512MB 内存 + 1000Mbps + RTT100 → 内存封顶，且等级 Level 1
compute_tcp_params 1000 100 512 512 512
A_RMEM="$TCP_RMEM_MAX"; A_LVL="$TCP_LEVEL_HINT"; A_BDP="$BDP_BYTES"
# BDP 预期 = 1000*100*1000/8 = 12500000
if [[ "$A_BDP" == "12500000" ]]; then ok "BDP 计算正确(A=$A_BDP)"; else bad "BDP 错误(A=$A_BDP, 期望12500000)"; fi
# 内存封顶：512MB 内存预算系数20%，per_conn 远小于 2*BDP，rmem 应被封顶且 >0 且 < 2*BDP
if [[ "$A_RMEM" -gt 0 && "$A_RMEM" -lt 25000000 ]]; then ok "内存预算封顶生效(A rmem_max=$A_RMEM<2×BDP)"; else bad "内存封顶异常(A rmem_max=$A_RMEM)"; fi
if [[ "$A_LVL" == *"Level 1"* ]]; then ok "等级判定正确(A=$A_LVL)"; else bad "等级错误(A=$A_LVL)"; fi

# 用例B：8GB 内存 + 100Mbps + RTT6 → 等级 Level 3，BDP 较小
compute_tcp_params 100 6 7000 8192 256
B_RMEM="$TCP_RMEM_MAX"; B_LVL="$TCP_LEVEL_HINT"; B_BDP="$BDP_BYTES"
if [[ "$B_BDP" == "75000" ]]; then ok "BDP 计算正确(B=$B_BDP)"; else bad "BDP 错误(B=$B_BDP, 期望75000)"; fi
if [[ "$B_LVL" == *"Level 3"* ]]; then ok "等级判定正确(B=$B_LVL)"; else bad "等级错误(B=$B_LVL)"; fi

# ---------- 3. 全模块 mock 冒烟 + JSON 合法性 ----------
echo ""
echo "=== 3. 全模块 mock 冒烟 + JSON 校验 ==="
run_mod() { bash "$MODS/$1" "${@:2}" >/dev/null 2>&1; }

# 先跑检测链，填充 mock/data
run_mod system_detect.sh
run_mod tcp_detect.sh
run_mod network_quality.sh
run_mod bandwidth_test.sh --yes
run_mod congestion_control.sh
run_mod qdisc_manager.sh
run_mod nic_optimizer.sh
run_mod mtu_mss.sh
run_mod network_detect.sh
run_mod adaptive_engine.sh

declare -a JSONS=(hardware tcp_detect_result network_quality bandwidth congestion_control qdisc nic mtu_mss network_analysis recommendations)
for j in "${JSONS[@]}"; do
  f="$MOCK_P/data/$j.json"
  if [[ -f "$f" ]]; then
    # Windows 版 python3 不识别 Git-Bash 挂载路径，用 cygpath -m 转为可读取形式（Linux 下 cygpath 不存在则回退原路径）
    fw="$(cygpath -m "$f" 2>/dev/null || echo "$f")"
    if python3 -c "import json,sys; json.load(open(r'$fw'))" 2>/dev/null; then ok "$j.json 合法且存在"; else bad "$j.json 非合法 JSON"; echo "----- $j.json python 错误 -----"; python3 -c "import json; json.load(open(r'$fw'))" 2>&1 | tail -2; echo "----- 内容片段 -----"; head -c 600 "$f"; echo; fi
  else
    bad "$j.json 缺失（模块未生成）"
  fi
done

# ---------- 4. safe_config 干跑 / 备份 ----------
echo ""
echo "=== 4. safe_config 干跑 / 备份 ==="
if bash "$MODS/safe_config.sh" --dry-run 2>&1 | grep -q "net.ipv4.tcp_rmem"; then ok "safe_config --dry-run 输出真实配置"; else bad "safe_config --dry-run 未输出 tcp_rmem 配置"; fi
if bash "$MODS/safe_config.sh" --backup 2>&1 | grep -q "已执行备份\|备份"; then ok "safe_config --backup 执行"; else bad "safe_config --backup 未执行"; fi
if [[ -d "$MOCK_P/backup" && "$(ls -1 "$MOCK_P/backup" 2>/dev/null | wc -l)" -ge 1 ]]; then ok "备份目录已生成快照"; else bad "备份目录为空"; fi

# 4.x 擦除再写幂等回归测试（需求：写入前先彻底擦除旧配置）
echo "--- 擦除再写幂等 ---"
# 引入 safe_config 的函数（含 write_config_file），不触发其 main（source 而非执行）
source "$MODS/safe_config.sh" 2>/dev/null
CONF_DIR="$MOCK_P/etc/sysctl.d"
mkdir -p "$CONF_DIR"
CONF_FILE="$CONF_DIR/90-vno-ai.conf"
# 预置“上一次”残留配置：含旧值 + 当前建议不再包含的 key(tcp_sack)
printf '%s\n' \
  "# 旧配置残留" \
  "net.ipv4.tcp_rmem = 4096 87380 6291456" \
  "net.ipv4.tcp_sack = 0" \
  "net.ipv4.tcp_window_scaling = 1" > "$CONF_FILE"
# 同目录历史版本残留文件，应被一并清理
printf '# 旧版本文件\nnet.ipv4.tcp_rmem = 1 2 3\n' > "$CONF_DIR/90-network-vno-ai.conf"
NEW_CONTENT="# Network-VNO-AI 自动生成配置
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 87380 8388608
net.core.rmem_max = 8388608"
if write_config_file "$NEW_CONTENT"; then
  if grep -q "net.ipv4.tcp_sack" "$CONF_FILE"; then bad "擦除再写失败：旧 key(tcp_sack) 仍残留"; else ok "擦除再写：旧 key(tcp_sack) 已清除"; fi
  if grep -q "net.ipv4.tcp_rmem = 4096 87380 8388608" "$CONF_FILE"; then ok "擦除再写：新配置已写入"; else bad "新配置未写入"; fi
  if [[ -e "$CONF_DIR/90-network-vno-ai.conf" ]]; then bad "历史残留文件未清理"; else ok "同目录旧版本配置已清理"; fi
  if grep -q "net.ipv4.tcp_rmem = 1 2 3" "$CONF_FILE"; then bad "误写入旧版本文件内容"; else ok "未混入旧版本内容"; fi
else
  bad "write_config_file 执行失败"
fi

# ---------- 5. benchmark 闭环评价：基于调优前后真实对比（非预设） ----------
echo ""
echo "=== 5. benchmark 闭环评价（真实对比） ==="
source "$MODS/benchmark.sh" 2>/dev/null
BD="$MOCK_P/data"
EVF="$(cygpath -m "$BD/benchmark_evaluation.json" 2>/dev/null || echo "$BD/benchmark_evaluation.json")"

# 用例1：调优参数真变了 + 网络指标改善 → 应判定「优化有效」
cat > "$BD/benchmark_baseline.json" <<'EOF'
{
  "rtt_avg_ms": "100",
  "download_mbps": "100",
  "tcp_retrans_segs": 50,
  "ap_tcp_rmem_max": "87380",
  "ap_tcp_wmem_max": "16384",
  "ap_tcp_congestion_control": "cubic",
  "ap_tcp_window_scaling": "1",
  "ap_tcp_moderate_rcvbuf": "1",
  "ap_core_rmem_max": "212992",
  "ap_core_wmem_max": "212992",
  "ap_default_qdisc": "pfifo_fast"
}
EOF
cat > "$BD/benchmark_after.json" <<'EOF'
{
  "rtt_avg_ms": "90",
  "download_mbps": "105",
  "tcp_retrans_segs": 30,
  "ap_tcp_rmem_max": "8388608",
  "ap_tcp_wmem_max": "4194304",
  "ap_tcp_congestion_control": "bbr",
  "ap_tcp_window_scaling": "1",
  "ap_tcp_moderate_rcvbuf": "1",
  "ap_core_rmem_max": "8388608",
  "ap_core_wmem_max": "4194304",
  "ap_default_qdisc": "fq"
}
EOF
evaluate >/dev/null 2>&1
PV="$(python3 -c "import json;print(json.load(open(r'$EVF'))['params_changed'])" 2>/dev/null)"
VV="$(python3 -c "import json;print(json.load(open(r'$EVF'))['verdict'])" 2>/dev/null)"
if [[ "$PV" == "是" ]]; then ok "评价识别到参数已变化（params_changed=是）"; else bad "参数变化未被识别($PV)"; fi
if echo "$VV" | grep -q "优化有效"; then ok "调优后改善被正确判定为「优化有效」"; else bad "未正确判定优化有效: $VV"; fi

# 用例2：网络测量数据不足 → 诚实退出，绝不假装「不显著」
cat > "$BD/benchmark_after.json" <<'EOF'
{
  "rtt_avg_ms": "未测得",
  "download_mbps": "未测得",
  "tcp_retrans_segs": 0,
  "ap_tcp_rmem_max": "8388608",
  "ap_tcp_wmem_max": "4194304",
  "ap_tcp_congestion_control": "bbr",
  "ap_tcp_window_scaling": "1",
  "ap_tcp_moderate_rcvbuf": "1",
  "ap_core_rmem_max": "8388608",
  "ap_core_wmem_max": "4194304",
  "ap_default_qdisc": "fq"
}
EOF
evaluate >/dev/null 2>&1
DS="$(python3 -c "import json;print(json.load(open(r'$EVF'))['data_sufficient'])" 2>/dev/null)"
VV2="$(python3 -c "import json;print(json.load(open(r'$EVF'))['verdict'])" 2>/dev/null)"
if echo "$DS" | grep -qi "false" && [[ "$VV2" == *"数据不足"* ]]; then ok "数据不足时诚实退出（data_sufficient=false，未假装不显著）"; else bad "数据不足未诚实处理: data_sufficient=$DS verdict=$VV2"; fi

# 用例3：参数未变 + 指标不显著 → 明确区别于「优化有效」，不谎报
cat > "$BD/benchmark_after.json" <<'EOF'
{
  "rtt_avg_ms": "101",
  "download_mbps": "100",
  "tcp_retrans_segs": 50,
  "ap_tcp_rmem_max": "87380",
  "ap_tcp_wmem_max": "16384",
  "ap_tcp_congestion_control": "cubic",
  "ap_tcp_window_scaling": "1",
  "ap_tcp_moderate_rcvbuf": "1",
  "ap_core_rmem_max": "212992",
  "ap_core_wmem_max": "212992",
  "ap_default_qdisc": "pfifo_fast"
}
EOF
evaluate >/dev/null 2>&1
PV3="$(python3 -c "import json;print(json.load(open(r'$EVF'))['params_changed'])" 2>/dev/null)"
VV3="$(python3 -c "import json;print(json.load(open(r'$EVF'))['verdict'])" 2>/dev/null)"
if [[ "$PV3" == "否" && "$VV3" == *"未变化且网络指标变化不显著"* ]]; then ok "参数未变且无收益时如实判定（不谎报优化有效）"; else bad "未如实判定: params_changed=$PV3 verdict=$VV3"; fi

# 用例4：调优参数真变了 + 网络真实退化 → 结论须含具体指标数值与方向，不能笼统
cat > "$BD/benchmark_baseline.json" <<'EOF'
{
  "rtt_avg_ms": "50",
  "download_mbps": "100",
  "tcp_retrans_segs": 10,
  "ap_tcp_rmem_max": "87380",
  "ap_tcp_wmem_max": "16384",
  "ap_tcp_congestion_control": "cubic",
  "ap_tcp_window_scaling": "1",
  "ap_tcp_moderate_rcvbuf": "1",
  "ap_core_rmem_max": "212992",
  "ap_core_wmem_max": "212992",
  "ap_default_qdisc": "pfifo_fast"
}
EOF
cat > "$BD/benchmark_after.json" <<'EOF'
{
  "rtt_avg_ms": "65",
  "download_mbps": "90",
  "tcp_retrans_segs": 20,
  "ap_tcp_rmem_max": "4194304",
  "ap_tcp_wmem_max": "16384",
  "ap_tcp_congestion_control": "bbr",
  "ap_tcp_window_scaling": "1",
  "ap_tcp_moderate_rcvbuf": "1",
  "ap_core_rmem_max": "8388608",
  "ap_core_wmem_max": "212992",
  "ap_default_qdisc": "fq"
}
EOF
evaluate >/dev/null 2>&1
PV4="$(python3 -c "import json;print(json.load(open(r'$EVF'))['params_changed'])" 2>/dev/null)"
VV4="$(python3 -c "import json;print(json.load(open(r'$EVF'))['verdict'])" 2>/dev/null)"
NS4="$(python3 -c "import json;print(json.load(open(r'$EVF'))['net_summary'])" 2>/dev/null)"
if [[ "$PV4" == "是" && "$VV4" == *"未观察到收益且出现退化"* && "$VV4" == *"RTT 50.00→65.00ms"* && "$VV4" == *"带宽 100.00→90.00Mbps"* && "$NS4" == *"RTT 50.00→65.00ms"* && "$NS4" == *"带宽 100.00→90.00Mbps"* ]]; then
  ok "退化场景结论含具体实测数值与方向（RTT/带宽真实变化已写入，非笼统措辞）"
else
  bad "退化场景描述不真实: params_changed=$PV4 | verdict=$VV4 | net_summary=$NS4"
fi

# ---------- 6. 状态面板：真实标识 已生效 / 未生效 / 未应用 ----------
echo ""
echo "=== 6. 状态面板（实际应用状态标识） ==="
SP="$MODS/status_panel.sh"

# 用例1：无配置文件 → 应明确「尚未生成 / 未应用」并给下一步指引
rm -f "$MOCK_P/etc/sysctl.d/90-vno-ai.conf"
OUT1="$(bash "$SP" 2>&1)"
if echo "$OUT1" | grep -q "尚未生成" && echo "$OUT1" | grep -qF "○ 未应用 " && echo "$OUT1" | grep -q "尚未应用任何优化"; then
  ok "未应用时如实标注（尚未生成 / 未应用 + 下一步指引）"
else
  bad "未应用状态标识不正确"
fi

# 用例2：配置与系统实际一致 → 应标「✓ 已生效」（含多值 tcp_rmem 的制表符/空格归一化）
cat > "$MOCK_P/etc/sysctl.d/90-vno-ai.conf" <<'EOF'
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 87380 6291456
net.core.rmem_max = 212992
EOF
OUT2="$(bash "$SP" 2>&1)"
if echo "$OUT2" | grep -qF "✓ 已生效 "; then ok "配置与系统一致时标注「✓ 已生效」（多值 tcp_rmem 正确比对）"; else bad "已生效标识缺失"; fi
if echo "$OUT2" | grep -qF "⚠ 未生效 "; then bad "全部一致时不应出现「未生效」标识"; else ok "全部一致时不误报「未生效」"; fi

# 用例3：配置写入 bbr 但系统仍 cubic → 必须标「⚠ 未生效」并提示重载/漂移
printf 'net.ipv4.tcp_congestion_control = bbr\n' >> "$MOCK_P/etc/sysctl.d/90-vno-ai.conf"
OUT3="$(bash "$SP" 2>&1)"
if echo "$OUT3" | grep -qF "⚠ 未生效 " && echo "$OUT3" | grep -q "已写入配置但未在系统中生效"; then
  ok "配置与系统不一致时标注「⚠ 未生效」并提示重载"
else
  bad "漂移（已写入未生效）未正确标注"
fi

# 用例4：compact 单行速览（菜单/巡检调用）
OUTC="$(bash "$SP" --compact 2>&1)"
if echo "$OUTC" | grep -q "状态速览" && echo "$OUTC" | grep -q "模块可用"; then ok "compact 单行速览可用（供菜单/巡检）"; else bad "compact 输出不正确"; fi

# ---------- 汇总 ----------
echo ""
echo "=========================================="
echo "测试结果：通过 $PASS，失败 $FAIL"
echo "=========================================="
# 清理 mock
rm -rf "$MOCK" 2>/dev/null || true
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
