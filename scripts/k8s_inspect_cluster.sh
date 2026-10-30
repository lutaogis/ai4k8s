#!/bin/bash
# K8s 集群巡检（只读，不修改任何状态）
PW="${SUDO_PW:?请先 export SUDO_PW=你的密码}"
S() { echo "$PW" | sudo -S "$@" 2>&1 | grep -v "^\[sudo\]"; return 0; }
ETCD="--endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"

echo "########## [01] 集群基本信息 ##########"
kubectl version 2>/dev/null | grep -E "Server Version|Client Version"
echo "-- healthz --"; kubectl get --raw /healthz 2>&1; echo
echo "-- API 响应时间(3次) --"
for i in 1 2 3; do /usr/bin/time -f "  %e s" kubectl get --raw /healthz > /dev/null 2>>/tmp/apitime; done
cat /tmp/apitime 2>/dev/null | grep " s"; rm -f /tmp/apitime
echo "-- 命名空间数 --"; kubectl get ns --no-headers 2>/dev/null | wc -l
echo "-- 全集群 Pod 数 --"; kubectl get pods -A --no-headers 2>/dev/null | wc -l

echo "########## [02] 节点状态 ##########"
kubectl get nodes -o wide 2>&1
echo "-- Conditions --"
for n in $(kubectl get nodes -o name 2>/dev/null | cut -d/ -f2); do
  echo "$n: $(kubectl get node $n -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)"
done
echo "-- Taints --"
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints --no-headers 2>/dev/null

echo "########## [03] 资源容量与分配率 ##########"
for n in $(kubectl get nodes -o name 2>/dev/null | cut -d/ -f2); do
  echo "--- $n ---"
  kubectl describe node $n 2>/dev/null | sed -n '/Allocated resources/,/Events/p' | grep -E "cpu|memory" | head -4
done

echo "########## [04] 控制面组件 ##########"
kubectl -n kube-system get pods -o wide 2>&1 | head -20
echo "-- 重启次数 Top5 --"
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount --no-headers 2>/dev/null | tail -5
echo "-- 组件近 1 小时 ERROR 日志量 --"
for p in $(kubectl -n kube-system get pods -o name 2>/dev/null | grep -E "apiserver|controller-manager|scheduler" | cut -d/ -f2); do
  c=$(kubectl -n kube-system logs $p --since=1h 2>/dev/null | grep -ciE "\bE[0-9]{4}|error")
  echo "  $p: $c 行"
done

echo "########## [05] etcd 集群 ##########"
S env ETCDCTL_API=3 etcdctl $ETCD endpoint status -w table 2>&1 | head -8
echo "-- health --"
S env ETCDCTL_API=3 etcdctl $ETCD endpoint health --cluster 2>&1 | head -5
echo "-- member --"
S env ETCDCTL_API=3 etcdctl $ETCD member list -w table 2>&1 | head -6
echo "-- alarm --"
S env ETCDCTL_API=3 etcdctl $ETCD alarm list 2>&1 | head -5
echo "-- etcd 数据目录大小 --"
S bash -c 'du -sh /var/lib/etcd 2>/dev/null | cut -f1' | sed 's/^/  /'

echo "########## [06] 网络与 DNS ##########"
echo "-- calico-node --"; kubectl -n kube-system get pods -l k8s-app=calico-node --no-headers 2>/dev/null | awk '{print $1,$2,$3,$4}'
echo "-- IPPool --"; kubectl get ippools.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr,BLOCK:.spec.blockSize --no-headers 2>/dev/null
echo "-- IPAM 已分配块 --"; kubectl get ipamblocks.crd.projectcalico.org --no-headers 2>/dev/null | wc -l
echo "-- CoreDNS --"; kubectl -n kube-system get deploy coredns --no-headers 2>/dev/null
echo "-- kube-proxy --"; kubectl -n kube-system get ds kube-proxy --no-headers 2>/dev/null
echo "-- VIP --"; ping -c2 -W2 192.168.1.100 2>&1 | tail -2
echo "-- VIP lease 持有者 --"; kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}  renewTime={.spec.renewTime}{"\n"}' 2>/dev/null
echo "-- Endpoints 为空的 Service --"
kubectl get endpoints -A --no-headers 2>/dev/null | awk '$3=="<none>"{print "  "$1"/"$2}' | head -5

echo "########## [07] 工作负载健康 ##########"
echo "-- 非 Running/Succeeded 的 Pod --"
kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"{print "  "$1,$2,$4,$5}' | head -10
echo "-- 未就绪 Deployment --"
kubectl get deploy -A --no-headers 2>/dev/null | awk '{
  split($3,r,"/"); if (r[1]+0 != r[2]+0) print "  "$1"/"$2" ready="$3
}' | head -10
echo "-- 失败 Job --"
kubectl get jobs -A --no-headers 2>/dev/null | awk '{print "  "$1"/"$2}' | head -5
echo "-- Evicted/被驱逐历史 --"
kubectl get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | grep -c Evicted

echo "########## [08] 存储 ##########"
echo "StorageClass: $(kubectl get sc --no-headers 2>/dev/null | wc -l) 个"
echo "PV: $(kubectl get pv --no-headers 2>/dev/null | wc -l) 个  PVC: $(kubectl get pvc -A --no-headers 2>/dev/null | wc -l) 个"
kubectl get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"{print "  未绑定: "$1"/"$2}' | head -5
echo "-- emptyDir 使用量 Top --"
S bash -c 'du -sh /var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir 2>/dev/null | sort -rh | head -3'

echo "########## [09] 证书有效期 ##########"
S kubeadm certs check-expiration 2>&1 | grep -vE "^\[sudo\]|^$" | head -18

echo "########## [10] 最近告警事件 ##########"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -8 | awk '{print "  "$1,$4,$5,substr($0,index($0,$6),80)}'

echo "########## [11] 安全基线 ##########"
echo "-- apiserver 关键参数 --"
S bash -c 'grep -oE "\-\-(audit-log-path|audit-policy-file|encryption-provider-config|anonymous-auth|authorization-mode)=[^ ]*" /etc/kubernetes/manifests/kube-apiserver.yaml | sort -u'
echo "-- 绑定 system:masters 的凭据 --"
kubectl get clusterrolebindings -o json 2>/dev/null | grep -c "system:masters"
echo "-- 拥有 cluster-admin 的 ServiceAccount --"
kubectl get clusterrolebinding -o json 2>/dev/null | awk '/name.*cluster-admin/{f=1} f&&/ServiceAccount/{print "  "$0}' | head -5
echo "-- NetworkPolicy 数量 --"; kubectl get netpol -A --no-headers 2>/dev/null | wc -l
echo "-- 命名空间 PSA 标签 --"; kubectl get ns -o custom-columns=NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce --no-headers 2>/dev/null | head -6
echo "-- 默认 SA 自动挂载 token 的工作负载数 --"
kubectl get deploy,sts,ds -A -o json 2>/dev/null | grep -c '"automountServiceAccountToken": false'

echo "########## [12] 备份状态 ##########"
S bash -c 'ls -lh /var/backups/etcd/*.db 2>/dev/null | tail -2'
echo "-- cron 配置 --"; S bash -c 'cat /etc/cron.d/etcd-backup 2>/dev/null'
echo "-- 最新快照年龄 --"
S bash -c 'f=$(ls -t /var/backups/etcd/*.db 2>/dev/null | head -1); [ -n "$f" ] && echo "  $(basename $f) $(stat -c%y $f | cut -d. -f1)"'
echo "-- PKI 包 --"; S bash -c 'ls -lh /root/k8s-pki-*.tar.gz 2>/dev/null | tail -1'

echo "########## [99] 巡检结束 ##########"
