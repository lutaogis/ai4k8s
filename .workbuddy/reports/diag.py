# -*- coding: utf-8 -*-
import paramiko, sys

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.103"
PW = "lumz1021"
ETCD_ARGS = ("--endpoints=https://127.0.0.1:2379 "
             "--cacert=/etc/kubernetes/pki/etcd/ca.crt "
             "--cert=/etc/kubernetes/pki/etcd/server.crt "
             "--key=/etc/kubernetes/pki/etcd/server.key")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username="lumz", password=PW, timeout=12, look_for_keys=False, allow_agent=False)

def run(cmd, t=90):
    _, out, err = c.exec_command(cmd, timeout=t)
    o = out.read().decode("utf-8", "replace").strip()
    e = err.read().decode("utf-8", "replace").strip()
    print("$", cmd[:100])
    print((o + ("\n" + e if e else ""))[:2000])
    print("-" * 40)
    return o

run("printf '%s\\n' '" + PW + "' | sudo -S bash -c 'crictl logs $(crictl ps --name kube-vip -q | head -1) 2>&1 | tail -12'")
run("printf '%s\\n' '" + PW + "' | sudo -S bash -c 'cid=$(crictl ps --name etcd -q | head -1); "
    "crictl exec $cid etcdctl " + ETCD_ARGS + " endpoint status -w table'")
run("printf '%s\\n' '" + PW + "' | sudo -S bash -c 'crictl logs $(crictl ps --name etcd -q | head -1) 2>&1 | "
    "grep -iE \"failed|lost leader|elected|health\" | tail -10'")
c.close()
