#!/bin/bash
E="--endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
which etcdctl >/dev/null 2>&1 && ETCDCTL_BIN=etcdctl || ETCDCTL_BIN=""
if [ -n "$ETCDCTL_BIN" ]; then
  $ETCDCTL_BIN $E member list -w table
  $ETCDCTL_BIN $E endpoint health --cluster
else
  CID=$(crictl ps --name etcd -q | head -1)
  crictl exec "$CID" etcdctl $E member list -w table
  crictl exec "$CID" etcdctl $E endpoint health --cluster
fi
