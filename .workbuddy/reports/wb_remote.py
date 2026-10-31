# -*- coding: utf-8 -*-
"""远程执行小工具：base64 传脚本 + sudo 提权，避免引号/管道/stdin 冲突"""
import base64
import socket
import paramiko

USER = "lumz"
PWD = "lumz1021"


def run(ip, script, sudo=True, timeout=180):
    """在远端执行 bash 脚本（base64 传输，可选 sudo 提权）"""
    b64 = base64.b64encode(script.encode("utf-8")).decode()
    pre = ""
    if sudo:
        pre = "printf '%s\\n' " + PWD + " | sudo -S -p '' "
    cmd = f"echo {b64} | base64 -d > /tmp/_wb_task.sh && {pre}bash /tmp/_wb_task.sh"
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip, username=USER, password=PWD, timeout=10, banner_timeout=10,
              look_for_keys=False, allow_agent=False)
    _, o, e = c.exec_command(cmd, timeout=timeout)
    out = o.read().decode("utf-8", "replace").strip()
    err = e.read().decode("utf-8", "replace").strip()
    c.close()
    return out, err


def alive(ip, timeout=4):
    """探测主机 22 端口是否可达"""
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((ip, 22))
        return True
    except Exception:
        return False
    finally:
        s.close()
