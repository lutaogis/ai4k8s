#!/bin/bash
# 阶段4：worker-05 节点侧 reset 与本地残留清理
echo "=== [1/7] kubeadm reset -f ==="
kubeadm reset -f 2>&1 | tail -12

echo "=== [2/7] 等待 30s（让 Calico 释放 IP 分配）==="
sleep 30

echo "=== [3/7] 清理残留容器 ==="
crictl ps -aq 2>/dev/null | xargs -r crictl rm -f >/dev/null 2>&1
crictl pods -q 2>/dev/null | xargs -r crictl rmp -f >/dev/null 2>&1
echo "剩余容器数: $(crictl ps -aq 2>/dev/null | wc -l)"

echo "=== [4/7] 清 CNI 配置与状态 ==="
rm -rf /etc/cni/net.d/* /var/lib/cni/
ls -la /etc/cni/net.d/ 2>&1 | head -3

echo "=== [5/7] 删 IPIP 隧道 ==="
ip link delete tunl0 2>/dev/null && echo "tunl0 deleted" || echo "tunl0 不存在（已清）"
ip link show tunl0 2>&1 | head -1

echo "=== [6/7] 清 iptables ==="
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
ip6tables -F && ip6tables -t nat -F && ip6tables -t mangle -F && ip6tables -X
echo "nat 表 cali 链数: $(iptables -t nat -S 2>/dev/null | grep -c cali)"
echo "filter 表 cali 链数: $(iptables -S 2>/dev/null | grep -c cali)"

echo "=== [7/7] 停用 kubelet ==="
systemctl disable kubelet 2>&1 | tail -1
systemctl stop kubelet 2>&1
echo "kubelet: $(systemctl is-active kubelet) / $(systemctl is-enabled kubelet)"

echo ""
echo "=== 最终校验 ==="
echo "-- /etc/kubernetes --"; ls -la /etc/kubernetes/ 2>&1 | head -6
echo "-- /etc/cni/net.d --"; ls /etc/cni/net.d/ 2>&1
echo "-- 10.244 路由 --"; ip route | grep 10.244 || echo "无残留 ✅"
echo "-- tunl0 --"; ip link show tunl0 2>&1 | head -1
echo "=== STAGE4 DONE ==="
