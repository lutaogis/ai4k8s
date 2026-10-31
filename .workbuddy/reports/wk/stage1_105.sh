#!/bin/bash
# 阶段1：k8s-worker-05 系统基线补齐（幂等）
echo "=== [1/6] /etc/hosts ==="
if ! grep -q "k8s-master-01" /etc/hosts; then
cat >> /etc/hosts <<'EOF'
192.168.1.100  k8s-vip
192.168.1.101  k8s-master-01
192.168.1.102  k8s-master-02
192.168.1.103  k8s-master-03
192.168.1.104  k8s-worker-01
192.168.1.105  k8s-worker-05
EOF
echo "hosts: appended"
else
echo "hosts: already present"
fi
grep 192.168.1 /etc/hosts

echo "=== [2/6] 时区 ==="
timedatectl set-timezone Asia/Shanghai
timedatectl | head -3

echo "=== [3/6] 关闭 swap ==="
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab
echo "swapon 输出（应为空）:"; swapon --show
grep -n swap /etc/fstab || echo "fstab: no active swap line"

echo "=== [4/6] 内核模块 ==="
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
ipip
EOF
modprobe overlay; modprobe br_netfilter; modprobe ipip
lsmod | grep -E '^(overlay|br_netfilter|ipip)\b'

echo "=== [5/6] sysctl ==="
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null 2>&1
sysctl -n net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables

echo "=== [6/6] 基础工具 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>&1 | tail -2
apt-get install -y -qq curl gnupg ca-certificates apt-transport-https 2>&1 | tail -3
which curl gpg

echo "=== STAGE1 DONE ==="
