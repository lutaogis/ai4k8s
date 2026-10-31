# ai4k8s — 3 控制面 + 2 worker 的高可用 Kubernetes 集群（文档与脚本集）

本工作区是 **ai4system.com 集群**（3 × Ubuntu 24.04 control-plane + 2 × worker）的完整知识库：
从方案设计 → 安装实施 → 实测排错 → 系统巡检 → 节点扩缩容 → 整机关机/开机 → 日常运维，形成闭环。
所有版本号、IP、命令均为 2026-10-30/31 实机验证值，可直接复现。

> 🔌 **当前状态（2026-10-31 22:22）：集群已整体关机（计划内停机）。**
> 恢复步骤见 [`k8s-cluster-shutdown-startup-plan.md`](k8s-cluster-shutdown-startup-plan.md) 第 2 章；上电后执行
> `python .workbuddy/reports/boot_verify.py` 做九项验证。

---

## 集群速览

| 项目 | 值 |
|---|---|
| 架构 | 3 × control-plane，stacked etcd，kube-vip ARP 模式 VIP |
| API 入口 | `https://192.168.1.100:6443`（VIP，漂移式） |
| 节点 | 控制面 k8s-master-01 (.101) / 02 (.102) / 03 (.103)，4C/15G/57G；worker **k8s-worker-01 (.104)** 与 **k8s-worker-02 (.105)**，均 **8C/31G/96G**（2026-10-31 扩容，共 5 节点；`.105` 原为 `k8s-worker-05`，当日改名归位） |
| 版本 | Kubernetes **v1.34.13** · containerd **2.2.1** · Calico **v3.33.0**（IPIP） · kube-vip **v0.8.9** |
| 网络 | 网卡 `ens160` · Pod `10.244.0.0/16` · Service `10.96.0.0/12` · DNS 域 `ai4system.com` |
| 镜像加速 | docker.io / ghcr.io / quay.io → daocloud 镜像站；控制面组件走阿里云 `registry.aliyuncs.com` |
| 当前状态（2026-10-30 巡检） | 运行健康度 **98/100** ✅ · 生产就绪度 **62/100** ⚠️（0 P0 / 7 P1 / 6 P2） |
| 当前运行状态 | **已整体关机**（2026-10-31 22:22，计划内停机，5/5 节点离线、VIP 已释放） |

```
                    API VIP 192.168.1.100 (kube-vip ARP)
                       │ 漂移，当前持有者 master-01
        ┌──────────────┼──────────────┐
   k8s-master-01  k8s-master-02  k8s-master-03
   192.168.1.101  192.168.1.102  192.168.1.103
   apiserver+etcd apiserver+etcd apiserver+etcd   ← stacked etcd，3 member
   Calico (IPIP)  Calico (IPIP)  Calico (IPIP)

   k8s-worker-01  192.168.1.104  8C/31G/96G     ← 纯工作节点，不参与 etcd/VIP
   k8s-worker-02  192.168.1.105  8C/31G/96G
   Calico (IPIP) / block 10.244.36.192/26 (w-01) · 10.244.118.64/26 (w-02)
```

拓扑图源文件：[k8s-topology.svg](k8s-topology.svg)

---

## 文档地图

| 文档 | 定位 | 什么时候看 |
|---|---|---|
| [`k8s-3node-control-plane-plan.md`](k8s-3node-control-plane-plan.md) | **方案论证**：HA 选型（kube-vip vs HAProxy vs 云 LB）、拓扑与网段规划、8 阶段实施大纲、常见坑 | 动手前理解"为什么这么设计"；扩容/重规划时参考 |
| [`k8s-add-worker-node-plan.md`](k8s-add-worker-node-plan.md) | **扩容计划与记录**：新增 worker（`k8s-worker-01/.104`、`.105`）的 5 阶段实施计划，含节点实测现状、基线差异清单、集群特化参数对齐、验收清单、回滚与执行记录 | 要给集群加计算节点时按此执行 |
| [`k8s-remove-worker-node-plan.md`](k8s-remove-worker-node-plan.md) | **缩容/移除计划与记录**：从集群踢出 worker 的 5 阶段操作（cordon→drain→reset→删节点→Calico IPAM 清理）、残留清理清单（含 tunl0 / ipamblock 补清）、"改名重加 / 彻底退役"两分支，附 `.105` 移除并改名 `k8s-worker-02` 的实测记录 | 要下线一台 worker 或给它改名时按此执行 |
| [`k8s-cluster-shutdown-startup-plan.md`](k8s-cluster-shutdown-startup-plan.md) | **整机关机/开机计划与记录**：关机前预检（systemd 自启项、kube-vip 托管方式）、etcd 快照与状态基线、逐台关机顺序（worker→master）、开机自愈链路与九项验证清单、断电/时钟漂移风险预案；含 2026-10-31 全关执行的实测记录 | 计划停机、机房搬迁、长时间断电维护前后按此执行 |
| [`k8s-control-plane-install-runbook.md`](k8s-control-plane-install-runbook.md) | **通用执行手册**：0→10 阶段逐步命令、每阶段验证标准、里程碑与耗时、回滚方案、FAQ、转生产端口清单 | 在新环境复现安装时的通用骨架 |
| [`k8s-ha-install-manual.md`](k8s-ha-install-manual.md) | **实测安装记录**（权威）：真实版本号（v1.34.13 / containerd 2.2.1）、11 条踩坑实录、脚本清单、销毁与重建、镜像加速三要素 | **复现安装以本手册为准**；三者冲突时以此为准 |
| [`k8s-inspection-report-2026-10-30.md`](k8s-inspection-report-2026-10-30.md) | **系统巡检报告**：39 检查点、P1/P2 问题清单与整改建议、巡检方法学（三层模型 + 阈值表） | 评估集群现状、安排整改、学习巡检方法 |
| [`k8s-ops-commands.md`](k8s-ops-commands.md) | **运维命令手册**：14 章 + 3 附录，五步排错法、Pod 状态字典、etcd 快照/恢复、高危命令红黑榜、症状反查索引；**第 14 章为 Web 管理面板（Headlamp / Kuboard）安装与使用手册** | 日常运维与排错时查命令；装/用 Web 面板时看第 14 章 |
| [`kuboard-install-runbook.md`](kuboard-install-runbook.md) | **面板速查卡**：两套面板的访问信息、组件清单、备份/升级/卸载命令（完整版见运维手册第 14 章） | 只想要端口和几条命令时 |
| [`kuboard-v4-install.yaml`](kuboard-v4-install.yaml) | Kuboard v4 集群内部署清单（kuboard + MariaDB + hostPath PV，NodePort 30080，含踩坑修正） | 复装或重建 Kuboard 时直接 apply |

> 三份安装文档的关系：方案（plan）→ 通用手册（runbook）→ **实测手册（ha-install-manual，冲突时以此为准）**。

## 脚本

| 脚本 | 作用 |
|---|---|
| [`scripts/k8s_inspect_cluster.sh`](scripts/k8s_inspect_cluster.sh) | 集群层只读巡检（节点/控制面/etcd/网络/证书等 12 项），在任一 master 上执行 |
| [`scripts/host_inspect.sh`](scripts/host_inspect.sh) | 主机层只读巡检（磁盘/inode/内存/OOM/IO/服务状态等 9 项），每台节点执行 |

```bash
export SUDO_PW='你的 sudo 密码'
bash scripts/k8s_inspect_cluster.sh   # 集群层
bash scripts/host_inspect.sh          # 主机层（每台）
```

**运维辅助脚本**（`.workbuddy/reports/`，需本机 Python + paramiko）：

| 脚本 | 作用 |
|---|---|
| [`wb_remote.py`](.workbuddy/reports/wb_remote.py) | 远程执行基础库：base64 传脚本 + `sudo` 提权，规避引号/管道/stdin 冲突（`printf 'pw\n' \| sudo -S bash -s` 会让密码吃掉 stdin，务必不用） |
| [`precheck_shutdown.py`](.workbuddy/reports/precheck_shutdown.py) | 关/开机前置预检：逐节点核对 containerd/kubelet 是否 `enabled`、VIP 托管方式、时间同步 |
| [`boot_verify.py`](.workbuddy/reports/boot_verify.py) | 开机后一键验证：等 master→apiserver→worker 就绪，输出 nodes / etcd 健康 / VIP 落点 / 非 Running Pod / calico-node 副本 / 面板连通性 |

---

## 核心结论与待办（来自 2026-10-30 巡检）

**运行健康**：3 节点 Ready、控制面 9 个静态 Pod 零重启、etcd 3 member raft index 一致、VIP 0% 丢包、无异常 Pod。

**生产就绪短板（P1，上线前必须处理）**：

| # | 问题 | 整改方向 |
|---|---|---|
| P1-1 | 无审计日志 | apiserver 配 audit policy + logrotate |
| P1-2 | etcd Secret 明文存储 | 配 EncryptionConfiguration（aescbc） |
| P1-3 | 0 个 NetworkPolicy | 业务 ns 加 default-deny-ingress |
| P1-4 | 无 metrics-server | 部署后 `kubectl top` / HPA 才可用 |
| P1-5 | 控制面兼跑业务（无 worker） | 长期：加 2–3 台 worker 并恢复污点 —— **2026-10-31 已加 2 台 worker（.104/.105），但 master 污点仍未恢复，业务 Pod 仍可调度到控制面** |
| P1-6 | 节点无资源预留 | kubelet 加 systemReserved + evictionHard |
| P1-7 | etcd 备份仅本地单份、未演练 | 备份异地化；每季度真实恢复演练 |

**已修正的文档错误**：Calico 实际为 **IPIP 封装**（`ipipMode=Always`，存在 `tunl0`），此前部分文档误写为 VXLAN，已更正。

---

## 快速上手

```bash
# 集群健康一眼看（在任一 master）
kubectl get nodes -o wide && kubectl -n kube-system get pods -o wide
kubectl get --raw /healthz; echo

# VIP 当前持有者
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'

# etcd 健康（宿主机直连，勿用 kubectl exec）
sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint status -w table

# 新增节点（token 24h 过期，控制面另需证书 key）
kubeadm token create --print-join-command
sudo kubeadm init phase upload-certs --upload-certs
```

**计划停机速查**（完整流程与验证见计划文档）：

```bash
# 0) 预检 + 备份（必须在关机前）
python .workbuddy/reports/precheck_shutdown.py            # 确认 kubelet/containerd 均 enabled
sudo etcdctl ... snapshot save /var/backups/etcd/etcd-snap-pre-shutdown-$(date +%F).db

# 1) 关机顺序：worker → master（每台确认 SSH 失联后再下一台）
#    worker-01(.104) → worker-02(.105) → master-02(.102) → master-03(.103) → master-01(.101)
sudo shutdown -h now

# 2) 开机顺序：3 台 master 并行上电 → 等 etcd quorum + VIP 回抢 → 2 台 worker 上电
python .workbuddy/reports/boot_verify.py                  # 九项验证
```

> VIP 由 **kube-vip 静态 Pod** 托管（3 台 master 均有 `/etc/kubernetes/manifests/kube-vip.yaml`），开机关机无需人工干预；关机过程中 VIP 会自动漂移到仍在线的 master。

更多命令见 [`k8s-ops-commands.md`](k8s-ops-commands.md) 第 0 章"30 秒上手 12 条"与附录 B"按症状查命令"。

---

*集群与文档维护中；重大变更后请同步更新对应手册与巡检报告。*
