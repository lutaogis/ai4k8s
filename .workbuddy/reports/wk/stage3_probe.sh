#!/bin/bash
# 阶段3：kubeadm/kubelet/kubectl 1.34.13 + cri-tools
set -x
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.34/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.34/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
set +x
echo "=== 候选版本 ==="
apt-cache madison kubeadm | head -6
echo "=== 是否含 1.34.13-1.1 ==="
apt-cache madison kubeadm | grep -c "1.34.13-1.1"
