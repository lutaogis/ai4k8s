# -*- coding: utf-8 -*-
"""开机后一键验证（Phase B4 九项清单）
用法：python boot_verify.py
前提：3 台 master + 2 台 worker 已上电
"""
import socket
import sys
import time

import wb_remote as R

MASTERS = [("k8s-master-01", "192.168.1.101"),
           ("k8s-master-02", "192.168.1.102"),
           ("k8s-master-03", "192.168.1.103")]
WORKERS = [("k8s-worker-01", "192.168.1.104"),
           ("k8s-worker-02", "192.168.1.105")]
ALL = MASTERS + WORKERS
VIP = "192.168.1.100"


def port_open(ip, port, timeout=4):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def wait_ssh(nodes, limit=600, label=""):
    """等待节点 SSH 就绪"""
    print(f"\n[等待] {label} SSH 就绪（上限 {limit}s）")
    t0 = time.time()
    pending = list(nodes)
    while pending and time.time() - t0 < limit:
        still = []
        for n, ip in pending:
            if not R.alive(ip, 3):
                still.append((n, ip))
        if still != pending:
            ready = [n for n, _ in nodes if n not in [x[0] for x in still]]
            print(f"  {int(time.time()-t0):3d}s 已就绪: {', '.join(ready) if ready else '-'}")
        pending = still
        if pending:
            time.sleep(8)
    if pending:
        print(f"  ⚠ 超时未就绪: {', '.join(n for n, _ in pending)}")
        return False
    print(f"  ✅ 全部就绪，耗时 {time.time()-t0:.0f}s")
    return True


CHECK = r'''
export KUBECONFIG=/etc/kubernetes/admin.conf
echo "###NODES###"
kubectl get nodes -o wide 2>&1
echo "###ETCDHEALTH###"
CAC=/etc/kubernetes/pki/etcd/ca.crt; CRT=/etc/kubernetes/pki/etcd/server.crt; KEY=/etc/kubernetes/pki/etcd/server.key
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$CAC --cert=$CRT --key=$KEY endpoint health --cluster 2>&1 | sed 's/ took.*//'
echo "###ETCDMEM###"
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$CAC --cert=$CRT --key=$KEY member list 2>&1 | awk '{print $2, $3, $4}'
echo "###VIP###"
ip -o addr show | grep "192.168.1.100" || echo "VIP_NOT_ON_THIS_NODE"
echo "###UNHEALTHY###"
kubectl get pods -A 2>&1 | awk 'NR==1 || $4!="Running" && $4!="Completed"'
echo "###CALICO###"
kubectl -n kube-system get ds calico-node -o wide 2>&1
echo "###SVC###"
kubectl -n kube-system get pods | grep -cE "Running" 
'''


def main():
    print("=" * 66)
    print(" K8s 集群开机验证（Phase B4）")
    print("=" * 66)

    # B2: master 先起
    if not wait_ssh(MASTERS, 900, "3 台 master"):
        print("\n⚠ master 未全部就绪，请检查 hypervisor/电源状态"); sys.exit(1)

    print("\n[等待] apiserver 6443 就绪 ...")
    ok = False
    for _ in range(60):
        for _, ip in MASTERS:
            if port_open(ip, 6443, 3):
                print(f"  ✅ {ip}:6443 已响应")
                ok = True
                break
        if ok:
            break
        time.sleep(5)
    if not ok:
        print("  ⚠ apiserver 未就绪，检查 kubelet / 静态 Pod"); sys.exit(1)

    # B3: worker
    print("\n[提示] 现在请给 2 台 worker 上电，脚本将等待其 SSH 就绪 ...")
    wait_ssh(WORKERS, 900, "2 台 worker")

    # etcd quorum + 集群状态
    out, err = R.run("192.168.1.101", CHECK, timeout=180)
    print("\n" + "=" * 66)
    print(out)
    if err.strip():
        print("[stderr]", err[-300:])

    # 面板连通性
    print("\n[V6/V7] 面板连通性")
    for port, name in [(30080, "Kuboard"), (30081, "Headlamp")]:
        print(f"  {name:9s} {VIP}:{port} -> {'✅ 200/可达' if port_open(VIP, port) else '⚠ 不可达'}")

    print("\n" + "=" * 66)
    print(" 验证要点：nodes 5/5 Ready、etcd 3/3 healthy、VIP 在任一 master、")
    print("           UNHEALTHY 为空、calico-node DESIRED=5 READY=5")
    print("=" * 66)


if __name__ == "__main__":
    main()
