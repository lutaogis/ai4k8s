# -*- coding: utf-8 -*-
"""在 master-02 上做一份手工 etcd 快照，落到 /var/backups/etcd（仅新增文件，不动现有数据）"""
import paramiko, time

PW = "lumz1021"
HOST = "192.168.1.102"
ETCD_ARGS = ("--endpoints=https://127.0.0.1:2379 "
             "--cacert=/etc/kubernetes/pki/etcd/ca.crt "
             "--cert=/etc/kubernetes/pki/etcd/server.crt "
             "--key=/etc/kubernetes/pki/etcd/server.key")
SNAP = "etcd-snap-%s.db" % time.strftime("%Y%m%d-%H%M")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username="lumz", password=PW, timeout=15, look_for_keys=False, allow_agent=False)

def run(cmd, t=180):
    _, out, err = c.exec_command(cmd, timeout=t)
    o = out.read().decode("utf-8", "replace").strip()
    e = err.read().decode("utf-8", "replace").strip()
    print("$", cmd[:110])
    print((o + ("\n" + e if e else ""))[:1200])
    print("-" * 40)
    return o

pre = "printf '%s\\n' '%s' | sudo -S bash -c " % (PW, PW)

run(pre + "\"mkdir -p /var/backups/etcd && chmod 700 /var/backups/etcd\"")
run(pre + "\"cid=$(crictl ps --name etcd -q | head -1); crictl exec $cid etcdctl " + ETCD_ARGS +
    " snapshot save /var/lib/etcd/" + SNAP + "\"")
run(pre + "\"cid=$(crictl ps --name etcd -q | head -1); crictl exec $cid etcdctl " + ETCD_ARGS +
    " snapshot status /var/lib/etcd/" + SNAP + " -w table\"")
run(pre + "\"mv /var/lib/etcd/" + SNAP + " /var/backups/etcd/" + SNAP +
    " && chmod 600 /var/backups/etcd/" + SNAP + " && ls -lh /var/backups/etcd/\"")
c.close()
