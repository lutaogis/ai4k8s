#!/bin/bash
# 阶段4b：补清 Calico 路由 / tunl0 / 各表自定义链
echo "=== 清理前快照 ==="
echo "-- 10.244 路由 --"; ip route | grep 10.244
echo "-- nat 表 cali 链 --"; iptables -t nat -S 2>/dev/null | grep cali | head -12

echo ""
echo "=== [1/4] 删除 Calico 路由（proto 80）==="
ip route flush proto 80
echo "剩余 10.244 路由:"; ip route | grep 10.244 || echo "  无 ✅"

echo "=== [2/4] 删除 tunl0 ==="
ip link delete tunl0 2>/dev/null && echo "deleted" || echo "不存在"
ip link show tunl0 2>&1 | head -1

echo "=== [3/4] 清所有表的规则与自定义链（filter/nat/mangle/raw）==="
for t in filter nat mangle raw; do
  iptables -t $t -F 2>/dev/null
  iptables -t $t -X 2>/dev/null
done
for t in filter nat mangle raw; do
  ip6tables -t $t -F 2>/dev/null
  ip6tables -t $t -X 2>/dev/null
done
echo "各表残留 cali 链数:"
for t in filter nat mangle raw; do
  echo "  $t: $(iptables -t $t -S 2>/dev/null | grep -c cali)"
done
echo "各表残留 KUBE 链数:"
for t in filter nat mangle; do
  echo "  $t: $(iptables -t $t -S 2>/dev/null | grep -c KUBE)"
done

echo "=== [4/4] 最终校验 ==="
echo "-- /etc/kubernetes 内容 --"; ls -la /etc/kubernetes/ 2>&1 | tail -4
echo "-- /etc/cni/net.d --"; ls -A /etc/cni/net.d/ 2>&1 || echo "  空 ✅"
echo "-- 10.244 路由 --"; ip route | grep 10.244 || echo "  无 ✅"
echo "-- tunl0 --"; ip link show tunl0 2>&1 | head -1
echo "-- kubelet --"; systemctl is-active kubelet; systemctl is-enabled kubelet 2>&1
echo "-- 容器 --"; crictl ps -aq 2>/dev/null | wc -l
echo "=== STAGE4B DONE ==="
