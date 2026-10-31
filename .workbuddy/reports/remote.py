# -*- coding: utf-8 -*-
"""远程命令小工具：python remote.py "command" [--upload local remote]"""
import paramiko, sys

IP = "192.168.1.101"; USER = "lumz"; PW = "lumz1021"

def run(cmd, timeout=300):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(IP, username=USER, password=PW, timeout=15, look_for_keys=False, allow_agent=False)
    _, out, err = c.exec_command(cmd, timeout=timeout)
    o = out.read().decode("utf-8", "replace"); e = err.read().decode("utf-8", "replace")
    c.close()
    print(o)
    if e.strip(): print("--- STDERR ---\n" + e)

def upload(local, remote):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(IP, username=USER, password=PW, timeout=15, look_for_keys=False, allow_agent=False)
    s = c.open_sftp(); s.put(local, remote); s.close(); c.close()
    print(f"uploaded {local} -> {remote}")

if __name__ == "__main__":
    if sys.argv[1] == "--upload":
        upload(sys.argv[2], sys.argv[3])
    else:
        run(sys.argv[1])
