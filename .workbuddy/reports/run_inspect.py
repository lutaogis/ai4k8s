# -*- coding: utf-8 -*-
"""巡检驱动（容错版）：集群层在指定可达节点执行，主机层逐台执行，不可达节点记录后跳过。"""
import paramiko, os, socket, time, sys

USER = "lumz"
PW = "lumz1021"
SUDO_PW = "lumz1021"
BASE = r"C:/Ai4System/ai4k8s"
OUT = os.path.join(BASE, ".workbuddy", "reports")
os.makedirs(OUT, exist_ok=True)

NODES = [
    ("k8s-master-01", "192.168.1.101"),
    ("k8s-master-02", "192.168.1.102"),
    ("k8s-master-03", "192.168.1.103"),
    ("k8s-worker-01", "192.168.1.104"),
    ("k8s-worker-02", "192.168.1.105"),
]
CLUSTER_NODE = "192.168.1.102"   # 集群层巡检执行节点（master-01 不可达）

def port_open(ip, port=22, timeout=3):
    s = socket.socket(); s.settimeout(timeout)
    try:
        s.connect((ip, port)); return True
    except Exception:
        return False
    finally:
        s.close()

def connect(ip):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip, username=USER, password=PW, timeout=15, look_for_keys=False, allow_agent=False)
    return c

def upload(c, local, remote):
    sftp = c.open_sftp(); sftp.put(local, remote); sftp.close()

def run(c, cmd, timeout=420):
    _, out, err = c.exec_command(cmd, timeout=timeout)
    return out.read().decode("utf-8", "replace"), err.read().decode("utf-8", "replace")

def main():
    host_out = []
    skipped = []

    # ---- 集群层 ----
    print(f"== 集群层巡检 @ {CLUSTER_NODE} ...", flush=True)
    c = connect(CLUSTER_NODE)
    upload(c, os.path.join(BASE, "scripts", "k8s_inspect_cluster.sh"), "/tmp/k8s_inspect_cluster.sh")
    upload(c, os.path.join(BASE, "scripts", "host_inspect.sh"), "/tmp/host_inspect.sh")
    t0 = time.time()
    out, err = run(c, "cd /tmp && SUDO_PW='%s' bash k8s_inspect_cluster.sh" % SUDO_PW)
    with open(os.path.join(OUT, "raw_cluster.txt"), "w", encoding="utf-8") as f:
        f.write(out)
        if err.strip():
            f.write("\n\n### STDERR ###\n" + err)
    print(f"   完成 {time.time()-t0:.0f}s / {len(out.splitlines())} 行", flush=True)

    # ---- 主机层 ----
    for name, ip in NODES:
        if not port_open(ip):
            print(f"== [{name} {ip}] 不可达，跳过", flush=True)
            skipped.append((name, ip))
            host_out.append(f"===================== {name} ({ip}) =====================\n"
                            f"!!! 主机不可达（TCP 22 超时），未能采集。见集群层 Nodes 状态。\n")
            continue
        print(f"== [{name} {ip}] 主机层巡检 ...", flush=True)
        c2 = c if ip == CLUSTER_NODE else connect(ip)
        if ip != CLUSTER_NODE:
            upload(c2, os.path.join(BASE, "scripts", "host_inspect.sh"), "/tmp/host_inspect.sh")
        t0 = time.time()
        out, err = run(c2, "cd /tmp && SUDO_PW='%s' bash host_inspect.sh" % SUDO_PW, timeout=300)
        host_out.append(f"===================== {name} ({ip}) =====================\n{out}")
        if err.strip():
            host_out.append(f"### STDERR [{name}] ###\n{err}")
        print(f"   完成 {time.time()-t0:.0f}s", flush=True)
        if ip != CLUSTER_NODE:
            c2.close()
    c.close()

    with open(os.path.join(OUT, "raw_hosts.txt"), "w", encoding="utf-8") as f:
        f.write("\n\n".join(host_out))
    print("SKIPPED:", skipped, flush=True)
    print("DONE", flush=True)

if __name__ == "__main__":
    main()
