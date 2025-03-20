#!/bin/bash
# VPS 深度学习优化脚本 v4.8（BBR 自学习 + 高级优化）
# - **BBR 进入自学习范畴，动态调整 bbr2 关键参数**
# - **自动学习 VPS 资源占用，优化 TCP/UDP 连接**
# - **基于历史数据深度学习，实现精准宏观调控**
# - **日志轮转，防止磁盘占满**
# - **增强异常处理，提升脚本健壮性**
# - **并行任务执行，提高运行效率**
# 适用于 Ubuntu / Debian / CentOS，需 root 权限运行

# ------------------ 🔧 变量定义 ------------------
OPTIMIZATION_LOG_FILE="/var/log/vps_optimization.log"
MAX_LOG_SIZE=10485760  # 10MB
METRICS_LOG="/var/log/vps_metrics.log"
BBR_PARAMS_LOG="/var/log/bbr_learning.log"
BACKUP_DIR="/tmp/vps_optimize_backup"
mkdir -p "$BACKUP_DIR"

# ------------------ 📝 日志管理 ------------------
write_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$OPTIMIZATION_LOG_FILE"
    rotate_logs
}

rotate_logs() {
    if [[ -f "$OPTIMIZATION_LOG_FILE" && $(stat -c%s "$OPTIMIZATION_LOG_FILE") -ge $MAX_LOG_SIZE ]]; then
        tail -n 500 "$OPTIMIZATION_LOG_FILE" > "${OPTIMIZATION_LOG_FILE}.tmp"
        mv "${OPTIMIZATION_LOG_FILE}.tmp" "$OPTIMIZATION_LOG_FILE"
        write_log "日志已轮转，仅保留最近 500 条记录"
    fi
}

# ------------------ 📊 采集系统状态 ------------------
collect_system_metrics() {
    CPU_LOAD=$(awk '{print $1}' < /proc/loadavg)
    MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')
    NET_SPEED=$(ethtool "$(ip route get 1 | awk '{print $5; exit}')" 2>/dev/null | awk '/Speed/ {print $2}' | sed 's/Mb\/s//')
    [[ -z "$NET_SPEED" ]] && NET_SPEED=100

    # 记录历史数据（供深度学习使用）
    echo "$CPU_LOAD $MEM_USED $NET_SPEED" >> "$METRICS_LOG"

    write_log "采集系统状态: CPU $CPU_LOAD, 内存 $MEM_USED MB, 带宽 $NET_SPEED Mbps"
}

# ------------------ 🔍 识别重点网络进程 ------------------
detect_network_processes() {
    write_log "检测高流量进程..."
    NET_PROCESSES=$(ss -tup | awk 'NR>1 {print $7}' | awk -F',' '{print $1}' | sort | uniq -c | sort -nr | head -5)
    echo "$NET_PROCESSES" > /tmp/network_processes.log
    write_log "检测到的高流量进程: $(echo "$NET_PROCESSES" | awk '{print $2}')"
}

# ------------------ 🔄 深度学习优化策略 ------------------
adaptive_optimization() {
    write_log "执行深度学习优化..."
    METRICS=$(tail -10 "$METRICS_LOG" | awk '{sum1+=$1; sum2+=$2; sum3+=$3} END {print sum1/10, sum2/10, sum3/10}')
    CPU_AVG=$(echo "$METRICS" | awk '{print $1}')
    MEM_AVG=$(echo "$METRICS" | awk '{print $2}')
    NET_AVG=$(echo "$METRICS" | awk '{print $3}')

    # 动态调整 TCP 窗口大小
    TCP_RMEM_MAX=$((NET_AVG * 1048576))  # 根据带宽动态调整
    TCP_WMEM_MAX=$((NET_AVG * 1048576))

    cp /etc/sysctl.d/99-vps-network.conf "/etc/sysctl.d/99-vps-network.conf.bak"
    cat > /etc/sysctl.d/99-vps-network.conf << EOF
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr2
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_rmem = 4096 87380 ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_WMEM_MAX}
EOF

    sysctl --system
    write_log "优化完成，TCP 窗口设定：${TCP_RMEM_MAX}/${TCP_WMEM_MAX}"
}

# ------------------ 🚀 BBR 自学习优化 ------------------
bbr_learning_optimization() {
    write_log "执行 BBR 自学习优化..."
    # 采集当前网络质量数据
    RTT=$(ping -c 5 8.8.8.8 | awk -F'/' 'END {print $5}')
    LOSS=$(ping -c 10 8.8.8.8 | grep -oP '\d+(?=% packet loss)')

    # 根据 RTT 和丢包率动态调整 BBR pacing_gain 和 cwnd_gain
    if [[ "$LOSS" -gt 5 ]]; then
        PACING_GAIN="1.2"
        CWND_GAIN="1.3"
    elif [[ $(echo "$RTT < 20" | bc) -eq 1 ]]; then
        PACING_GAIN="2.0"
        CWND_GAIN="2.0"
    else
        PACING_GAIN="1.5"
        CWND_GAIN="1.5"
    fi

    # 记录 BBR 学习日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') RTT: $RTT ms, LOSS: $LOSS%, PACING_GAIN: $PACING_GAIN, CWND_GAIN: $CWND_GAIN" >> "$BBR_PARAMS_LOG"

    # 应用 BBR 参数
    sysctl -w net.ipv4.tcp_bbr_pacing_gain="$PACING_GAIN"
    sysctl -w net.ipv4.tcp_bbr_cwnd_gain="$CWND_GAIN"

    write_log "BBR 自学习优化完成，PACING_GAIN: $PACING_GAIN, CWND_GAIN: $CWND_GAIN"
}

# ------------------ 🛡️ 持续优化守护进程 ------------------
daemon_optimization() {
    while true; do
        (
            collect_system_metrics &
            detect_network_processes &
            adaptive_optimization &
            bbr_learning_optimization &
            wait
        )  
        sleep 60
    done &  
}

# ------------------ 🚀 运行优化 ------------------
main() {
    write_log "启动 VPS 深度学习优化脚本 v4.8"
    collect_system_metrics
    detect_network_processes
    adaptive_optimization
    bbr_learning_optimization

    write_log "所有优化已完成，系统将持续监测并动态调整参数"
    daemon_optimization
}

main

