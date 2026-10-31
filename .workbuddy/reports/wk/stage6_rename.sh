#!/bin/bash
# 阶段6a：改名 k8s-worker-05 -> k8s-worker-02
set -e
echo "=== 改名前 ==="
hostname; grep 192.168.1 /etc/hosts

echo ""
echo "=== [1/3] hostnamectl 改名 ==="
hostnamectl set-hostname k8s-worker-02
hostname

echo "=== [2/3] 更新 /etc/hosts ==="
# 127.0.1.1 行
sed -i 's/^127\.0\.1\.1.*/127.0.1.1  k8s-worker-02/' /etc/hosts
# 192.168.1.105 行
sed -i 's/^192\.168\.1\.105.*/192.168.1.105  k8s-worker-02/' /etc/hosts

echo "=== [3/3] 校验 ==="
hostname
echo "--- /etc/hosts ---"
cat /etc/hosts
echo "--- hostnamectl ---"
hostnamectl | head -4
echo "=== 改名完成 ==="
