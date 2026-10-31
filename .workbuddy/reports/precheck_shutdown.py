# -*- coding: utf-8 -*-
"""关机/开机计划前置预检：各节点 systemd 自启项 + 运行状态（只读，不改任何配置）"""
import paramiko
import concurrent.futures

NODES = [
    ("k8s-master-01", "192.168.1.101"),
    ("k8s-master-02", "192.168.1.102"),
    ("k8s-master-03", "192.168.1.103"),
    ("k8s-worker-01", "192.168.1.104"),
    ("k8s-worker-02", "192.168.1.105"),
]
USER = "lumz"
PASSWORD = "lumz1021"

# 需要确认 enabled 的服务
UNITS = ["containerd", "kubelet", "keepalived", "haproxy"]

CMD = (
    "printf 'pw\\n' | sudo -S -p '' bash -c '"
    "hostname; "
    "for u in containerd kubelet keepalived haproxy chronyd systemd-timesyncd; do "
    "printf \"%-20s enabled=%s active=%s\\n\" $u $(systemctl is-enabled $u 2>/dev/null || echo n/a) $(systemctl is-active $u 2>/dev/null || echo n/a); done; "
    "echo ---; "
    "uptime -s; "
    "ip addr show | grep -E \"192.168.1.10[0-5]/\" | head -3; "
    "echo ---; "
    "last -x shutdown reboot | head -5"
    "'"
).replace("pw", PASSWORD, 1)


def check(node):
    name, ip = node
    try:
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(ip, username=USER, password=PASSWORD, timeout=8, banner_timeout=8)
        _, out, err = c.exec_command(CMD, timeout=25)
        txt = out.read().decode("utf-8", "replace").strip()
        c.close()
        return f"===== {name} ({ip}) =====\n{txt}\n"
    except Exception as e:
        return f"===== {name} ({ip}) =====\nERROR: {e}\n"


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(5) as ex:
        for r in ex.map(check, NODES):
            print(r)
