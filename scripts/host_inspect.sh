#!/bin/bash
# 主机级巡检（只读）
PW="${SUDO_PW:?请先 export SUDO_PW=你的密码}"
S() { echo "$PW" | sudo -S "$@" 2>&1 | grep -v "^\[sudo\]"; return 0; }

echo "########## [H1] 基本信息 ##########"
echo "hostname: $(hostname)"
echo "os: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
echo "kernel: $(uname -r)"
echo "uptime: $(uptime -p) (since $(uptime -s))"
echo "cpu: $(nproc) 核  $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"

echo "########## [H2] 负载与内存 ##########"
uptime | awk -F'load average:' '{print "load:"$2}'
free -h | head -3
echo "swap: $(swapon --show --noheadings | wc -l) 个 分区启用"

echo "########## [H3] 磁盘 ##########"
df -h / /var/lib/etcd /var/lib/containerd 2>/dev/null | grep -vE "^Filesystem" | awk '{printf "  %-38s 用 %s/%s (%s)\n",$6,$3,$2,$5}'
echo "-- inode --"
df -i / 2>/dev/null | tail -1 | awk '{printf "  inode 用 %s/%s (%s)\n",$3,$2,$5}'
echo "-- etcd 数据大小 --"
S du -sh /var/lib/etcd 2>/dev/null
echo "-- containerd 数据大小 --"
S du -sh /var/lib/containerd 2>/dev/null
echo "-- 本地镜像数 --"
S crictl images -q 2>/dev/null | wc -l
echo "-- 磁盘 IO 等待(5s 采样) --"
vmstat 1 5 2>/dev/null | tail -1 | awk '{print "  wa="$16"%"}'

echo "########## [H4] 关键服务 ##########"
for s in kubelet containerd sshd; do
  printf "  %-12s %s (restarts=%s)\n" "$s" "$(systemctl is-active $s)" "$(systemctl show $s -p NRestarts --value)"
done
echo "-- 失败单元 --"
failed=$(systemctl --failed --no-legend | wc -l); echo "  $failed 个"

echo "########## [H5] 时间同步 ##########"
timedatectl | grep -E "System clock synchronized|NTP service|Time zone" | sed 's/^/  /'
chronyc tracking 2>/dev/null | grep -E "System time|Last offset" | sed 's/^/  /'

echo "########## [H6] 内核与硬件异常 ##########"
echo "-- OOM 记录(近 7 天) --"
S journalctl --since "7 days ago" 2>/dev/null | grep -ci "out of memory\|oom-killer" | sed 's/^/  /'
echo "-- IO / 文件系统错误 --"
S journalctl --since "7 days ago" -p err 2>/dev/null | grep -icE "i/o error|ext4-fs error|blk_update_request" | sed 's/^/  /'
echo "-- dmesg 中 error/warn 计数 --"
S dmesg 2>/dev/null | grep -ciE "error|fail" | sed 's/^/  /'

echo "########## [H7] 网络 ##########"
ip -brief addr show | grep -v LOOPBACK | sed 's/^/  /'
echo "-- 网卡错误/丢包 --"
for i in $(ls /sys/class/net | grep -vE "lo|cali|tunl|vxlan|cni"); do
  rx=$(cat /sys/class/net/$i/statistics/rx_errors 2>/dev/null); tx=$(cat /sys/class/net/$i/statistics/tx_errors 2>/dev/null)
  dr=$(cat /sys/class/net/$i/statistics/rx_dropped 2>/dev/null)
  printf "  %-10s rx_err=%s tx_err=%s rx_drop=%s\n" "$i" "$rx" "$tx" "$dr"
done
echo "-- conntrack --"
echo "  当前 $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null) / 上限 $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
echo "-- 文件句柄 --"
echo "  已用 $(S bash -c "cat /proc/sys/fs/file-nr | awk '{print \$1}'") / 上限 $(cat /proc/sys/fs/file-max 2>/dev/null)"
echo "-- 监听端口 --"
S ss -lntp 2>/dev/null | grep -E ":6443|:2379|:2380|:10250|:10257|:10259|:179|:5473" | awk '{print "  "$4, $6}' | sort -u | head -12

echo "########## [H8] kubelet 专项 ##########"
S systemctl status kubelet --no-pager 2>/dev/null | head -4 | sed 's/^/  /'
echo "-- kubelet 近期错误 --"
S journalctl -u kubelet --since "24 hours ago" -p err --no-pager 2>/dev/null | tail -5 | cut -c1-150 | sed 's/^/  /'
echo "-- containerd 近期错误 --"
S journalctl -u containerd --since "24 hours ago" -p err --no-pager 2>/dev/null | tail -5 | cut -c1-150 | sed 's/^/  /'

echo "########## [H9] Pod 容器数 ##########"
echo "  运行中容器: $(S crictl ps -q 2>/dev/null | wc -l)"
echo "  镜像总占用: $(S crictl imagefsinfo 2>/dev/null | grep -i "usedbytes" | head -1 | grep -oE "[0-9]+" | head -1 | awk '{printf "%.1f GB", $1/1024/1024/1024}')"
