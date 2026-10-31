#!/bin/bash
# 手工 etcd 快照（在 master-02 上跑，root 权限）
set -u
SNAP="etcd-snap-$(date +%Y%m%d-%H%M).db"
ARGS="--endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"

mkdir -p /var/backups/etcd && chmod 700 /var/backups/etcd

CID=$(crictl ps --name etcd -q | head -1)
echo "etcd container: $CID"

crictl exec "$CID" etcdctl $ARGS snapshot save "/var/lib/etcd/$SNAP"
crictl exec "$CID" etcdctl $ARGS snapshot status "/var/lib/etcd/$SNAP" -w table

mv "/var/lib/etcd/$SNAP" "/var/backups/etcd/$SNAP"
chmod 600 "/var/backups/etcd/$SNAP"
echo "--- /var/backups/etcd ---"
ls -lh /var/backups/etcd/
