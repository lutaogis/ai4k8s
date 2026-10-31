# K8s 集群整机关机 / 开机操作计划

> 集群：k8s-prod-ha（k8s-master-01/02/03 + k8s-worker-01/02）
> VIP：192.168.1.100（kube-vip 静态 Pod，ARP 模式，当前持有者 master-03）
> 版本：K8s v1.34.13 / containerd 2.2.1 / Calico v3.33.0（IPIP）
> 编制日期：2026-10-31
> 状态：**计划（待确认执行）**

---

## 0. 前置预检结论（2026-10-31 已完成，只读）

| 检查项 | 结果 | 影响 |
|---|---|---|
| containerd 自启 | 5 节点全部 `enabled` ✅ | 开机自动拉起 |
| kubelet 自启 | master-01/02/03、worker-01 `enabled` ✅；**worker-02 `disabled` ⚠️** | **worker-02 重启后将无法自启，必须先修复** |
| kube-vip | 3 master 均有静态 Pod `kube-vip.yaml` ✅ | 随 kubelet 自恢复，VIP 自动回抢 |
| 时间同步 | 5 节点 `systemd-timesyncd` 均 enabled+active ✅ | 开机后自动校时 |
| 当前 VIP 持有者 | master-03 (.103) | 关机顺序将 master 放最后，无需干预 |
| 节点运行时长 | master-01 今日 15:38 重启过；worker-01/02 今日 16:30/17:04 加入 | 正常 |

> **结论：唯一阻塞项 = worker-02 kubelet 未设自启。** 已纳入关机阶段第 1 步修复。

---

## 1. 关机计划（Phase S，预计 15~20 分钟）

### S1. 修复 worker-02 kubelet 自启（1 分钟，红线项）
```bash
# 在 k8s-worker-02 (.105) 上
sudo systemctl enable kubelet
systemctl is-enabled kubelet   # 必须输出 enabled
```

### S2. 关机前快照备份（2 分钟，强烈建议）
```bash
# 任一 master 上做 etcd 快照并下载到本地留档（沿用既有备份路径约定）
sudo kubectl -n kube-system exec etcd-k8s-master-01 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/backups/etcd/etcd-snap-pre-shutdown.db
# 并下载回本地 .workbuddy/reports/wk/etcd/ 归档
```
同时记录基线：`kubectl get nodes -o wide`、`kubectl get pods -A` 存档，供开机后比对。

### S3. 应用层善后（2 分钟，可选但建议）
- 如有 CronJob 在关机时段触发（跨夜关机会整段跳过），确认是否可接受；
- 确认无进行中的长任务（镜像拉取、滚动发布等）。

> 说明：**整机全关场景不做 drain**——所有节点同时下线，驱逐无意义，且 drain 会触发大规模 Pod 重建反而拖慢关机。直接逐台干净关机即可。

### S4. 逐台关机（顺序：worker → master，8~12 分钟）
原则：**每台等 SSH 彻底不通后再关下一台**，保证 etcd / kubelet 进程收到干净 SIGTERM。

| 步骤 | 节点 | 命令 | 确认方式 |
|---|---|---|---|
| S4.1 | k8s-worker-01 (.104) | `sudo shutdown -h now` | ping/ssh 超时 |
| S4.2 | k8s-worker-02 (.105) | `sudo shutdown -h now` | ping/ssh 超时 |
| S4.3 | k8s-master-02 (.102) | `sudo shutdown -h now` | ping/ssh 超时 |
| S4.4 | k8s-master-03 (.103) | `sudo shutdown -h now` | ping/ssh 超时（VIP 随之释放） |
| S4.5 | k8s-master-01 (.101) | `sudo shutdown -h now` | ping/ssh 超时 |

> master 关机次序无所谓 etcd 一致性（全部干净关闭，Raft 各成员正常退群），把 **master-01 放最后** 只是因为 Kuboard 的 hostPath PV 钉在它上面，留到最后可观察；实际全关无影响。
> 关机过程会伴随预期告警：etcd 2/3→1/3→失联、VIP 漂移/消失、面板 30080/30081 不可达——**这是正常现象，不是故障**。

### S5. 关机完成确认
- 5 台全部 ping 不通、VIP 192.168.1.100 无法访问；
- 本地归档 etcd 快照与状态基线文件。

---

## 2. 开机计划（Phase B，预计 10~15 分钟）

### B1. 先开 3 台 master（并行上电）
- k8s-master-01 / 02 / 03 同时上电（若为虚拟机/物理机，建议在 hypervisor/BIOS 层设置来电自启 + 上电顺序）。

### B2. 等待 master 自愈（约 3~5 分钟）
各组件自动恢复链路：systemd (containerd+kubelet 均已 enabled) → kubelet 拉起静态 Pod（etcd / apiserver / scheduler / controller-manager / kube-vip）→ etcd 3 成员互选形成 quorum → apiserver 就绪 → kube-vip 回抢 VIP。

逐项确认：
```bash
ssh lumz@192.168.1.101
systemctl is-active containerd kubelet          # 3 台均 active
sudo crictl ps | grep -E "etcd|apiserver|kube-vip"   # 均 Running
ip addr | grep 192.168.1.100                    # 应在某台 master 上出现
```
> **时钟注意**：若关机跨了较长时间，开机后 timesyncd 校时前，etcd 可能短暂报 clock skew/raft 告警，等 NTP 同步完成（通常 <1 分钟）即自愈，不要在这时急着重启。

### B3. 再开 2 台 worker
- k8s-worker-01 (.104)、k8s-worker-02 (.105) 上电，等 kubelet 注册回集群（1~2 分钟）。
> 开机顺序必须 master 在前：worker 起来时 apiserver 已就绪，Calico/CoreDNS 等插件 Pod 才能正常调度与拉取配置。

### B4. 开机后验证清单（对照关机前基线）
| # | 验证项 | 通过标准 |
|---|---|---|
| V1 | `kubectl get nodes` | 5/5 Ready（含 worker-02） |
| V2 | etcd 健康 | `etcdctl endpoint health` 3/3 |
| V3 | VIP | 192.168.1.100 可访问 apiserver 6443 |
| V4 | 核心 Pod | kube-system 全 Running（calico-node ×5、calico-kube-controllers、coredns、kube-proxy ×5、kube-vip ×3） |
| V5 | Calico 网络 | 跨节点 Pod ping 通、IPIP 隧道恢复 |
| V6 | Kuboard | http://192.168.1.100:30080 → 200 |
| V7 | Headlamp | http://192.168.1.100:30081 → 200 |
| V8 | DNS 解析 | Pod 内解析 `*.ai4system.com` 正常 |
| V9 | 比对基线 | pods -A 与关机前一致（允许重建的 Pod 名带随机后缀） |

### B5. 异常处置预案（如某节点开机后 NotReady）
```bash
# 按【从现象到根因】顺序排查：
journalctl -u kubelet -n 50 --no-pager          # 最常见：kubelet 未自启（本次已修复 worker-02）
systemctl is-enabled kubelet containerd          # 确认 enabled
sudo crictl ps -a | head                         # sandbox 是否卡 ImagePullBackOff
ip route | grep 10.244                           # calico 路由是否重建
```
极端情况兜底：用关机前 etcd 快照恢复（手册第 8 章既有流程）。

---

## 3. 关机/开机对照速查

```
关机：修 kubelet(worker-02) → etcd 备份 → worker(.104→.105) → master(.102→.103→.101)
开机：master ×3 并行 → 等 etcd quorum + VIP 回抢 → worker ×2 → 九项验证
```

## 4. 执行记录（Phase S 已完成 2026-10-31 22:15~22:22）

| 步骤 | 动作 | 结果 |
|---|---|---|
| S1 | worker-02 `systemctl enable kubelet` | ✅ 已建 symlink，复核 `enabled`（`/etc/systemd/system/multi-user.target.wants/kubelet.service`） |
| S2 | etcd 快照 | ✅ `/var/backups/etcd/etcd-snap-pre-shutdown-20261031-2215.db`，7.5MB，md5 `e30a4a29e0b2215fe889ceadcfad161a`，revision 374361 / 2444 keys；已下载本地 `.workbuddy/reports/wk/etcd/`（7.4MB） |
| S2 | 状态基线 | ✅ `.workbuddy/reports/wk/baseline/cluster-baseline-20261031-2215.txt`（5 节点 Ready、etcd 3/3 healthy、无 CronJob、PV 1 个） |
| S3 | CronJob 检查 | ✅ 集群内无 CronJob，无跨夜触发风险 |
| S4.1 | worker-01 (.104) shutdown | ✅ 2s 后 SSH 不可达 |
| S4.2 | worker-02 (.105) shutdown | ✅ 2s 后 SSH 不可达 |
| S4.3 | master-02 (.102) shutdown | ✅ 2s 后 SSH 不可达 |
| S4.4 | master-03 (.103, VIP 持有者) shutdown | ✅ 2s 后不可达；VIP 6443 短暂由剩余 master 接管（kube-vip 漂移正常） |
| S4.5 | master-01 (.101) shutdown | ✅ 2s 后 SSH 不可达 |
| S5 | 关机确认 | ✅ 5/5 节点 SSH OFFLINE，VIP 192.168.1.100:6443 不可达 |

**关机前最后一次确认的状态**：5 节点 Ready，etcd 3/3 healthy（master-01/02/03 各耗时 10.7/11.9/15.0ms），Kuboard Pod 在 master-03、kuboard-db 在 master-01，Headlamp 在 master-02。

> 经验：`printf 'pw\n' | sudo -S bash -s` 写法会让密码占用 stdin 导致后续命令以普通用户执行（快照报 `server.key: permission denied`）。正确做法是脚本 base64 传远端后 `sudo bash /tmp/x.sh`（封装在 `.workbuddy/reports/wb_remote.py`）。

---

## 5. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| worker-02 kubelet 未自启 | 高（已修复项） | S1 步骤强制执行并复核 |
| 跨夜关机 CronJob 跳过触发 | 低 | S3 确认业务可接受 |
| 开机后时钟漂移导致 etcd 告警 | 低 | 等 NTP 同步，不急重启 |
| 断电非正常关机（非 shutdown） | 中 | 尽量走 `shutdown -h now`，etcd 有 WAL 可恢复 |
