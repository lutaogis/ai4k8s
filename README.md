# ai4k8s — 3 节点高可用 Kubernetes 控制平面（文档与脚本集）

本工作区是 **ai4system.com 集群**（3 × Ubuntu 24.04 control-plane）的完整知识库：
从方案设计 → 安装实施 → 实测排错 → 系统巡检 → 日常运维，形成闭环。
所有版本号、IP、命令均为 2026-10-30 实机验证值，可直接复现。

---

## 集群速览

| 项目 | 值 |
|---|---|
| 架构 | 3 × control-plane，stacked etcd，kube-vip ARP 模式 VIP |
| API 入口 | `https://192.168.1.100:6443`（VIP，漂移式） |
| 节点 | k8s-master-01 (.101) / 02 (.102) / 03 (.103)，VMware 虚机，4C/15G/57G |
| 版本 | Kubernetes **v1.34.13** · containerd **2.2.1** · Calico **v3.33.0**（IPIP） · kube-vip **v0.8.9** |
| 网络 | 网卡 `ens160` · Pod `10.244.0.0/16` · Service `10.96.0.0/12` · DNS 域 `ai4system.com` |
| 镜像加速 | docker.io / ghcr.io / quay.io → daocloud 镜像站；控制面组件走阿里云 `registry.aliyuncs.com` |
| 当前状态（2026-10-30 巡检） | 运行健康度 **98/100** ✅ · 生产就绪度 **62/100** ⚠️（0 P0 / 7 P1 / 6 P2） |

```
                    API VIP 192.168.1.100 (kube-vip ARP)
                       │ 漂移，当前持有者 master-01
        ┌──────────────┼──────────────┐
   k8s-master-01  k8s-master-02  k8s-master-03
   192.168.1.101  192.168.1.102  192.168.1.103
   apiserver+etcd apiserver+etcd apiserver+etcd   ← stacked etcd，3 member
   Calico (IPIP)  Calico (IPIP)  Calico (IPIP)
```

拓扑图源文件：[k8s-topology.svg](k8s-topology.svg)

---

## 文档地图

| 文档 | 定位 | 什么时候看 |
|---|---|---|
| [`k8s-3node-control-plane-plan.md`](k8s-3node-control-plane-plan.md) | **方案论证**：HA 选型（kube-vip vs HAProxy vs 云 LB）、拓扑与网段规划、8 阶段实施大纲、常见坑 | 动手前理解"为什么这么设计"；扩容/重规划时参考 |
| [`k8s-control-plane-install-runbook.md`](k8s-control-plane-install-runbook.md) | **通用执行手册**：0→10 阶段逐步命令、每阶段验证标准、里程碑与耗时、回滚方案、FAQ、转生产端口清单 | 在新环境复现安装时的通用骨架 |
| [`k8s-ha-install-manual.md`](k8s-ha-install-manual.md) | **实测安装记录**（权威）：真实版本号（v1.34.13 / containerd 2.2.1）、11 条踩坑实录、脚本清单、销毁与重建、镜像加速三要素 | **复现安装以本手册为准**；三者冲突时以此为准 |
| [`k8s-inspection-report-2026-10-30.md`](k8s-inspection-report-2026-10-30.md) | **系统巡检报告**：39 检查点、P1/P2 问题清单与整改建议、巡检方法学（三层模型 + 阈值表） | 评估集群现状、安排整改、学习巡检方法 |
| [`k8s-ops-commands.md`](k8s-ops-commands.md) | **运维命令手册**：13 章 + 3 附录，五步排错法、Pod 状态字典、etcd 快照/恢复、高危命令红黑榜、症状反查索引 | 日常运维与排错时查命令 |

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
| P1-5 | 控制面兼跑业务（无 worker） | 长期：加 2–3 台 worker 并恢复污点 |
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

更多命令见 [`k8s-ops-commands.md`](k8s-ops-commands.md) 第 0 章"30 秒上手 12 条"与附录 B"按症状查命令"。

---

*集群与文档维护中；重大变更后请同步更新对应手册与巡检报告。*
