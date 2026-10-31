#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq kubeadm=1.34.13-1.1 kubelet=1.34.13-1.1 kubectl=1.34.13-1.1 2>&1 | tail -5
apt-mark hold kubeadm kubelet kubectl
apt-get install -y -qq cri-tools 2>&1 | tail -3
echo "=== 版本 ==="
kubeadm version -o short
kubelet --version
kubectl version --client -o yaml 2>/dev/null | grep gitVersion
crictl --version
echo "=== hold 状态 ==="
apt-mark showhold
echo "=== kubelet 服务 ==="
systemctl enable kubelet 2>&1 | tail -2
systemctl is-enabled kubelet; systemctl is-active kubelet
