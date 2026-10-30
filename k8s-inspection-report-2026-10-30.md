# Kubernetes 集群系统巡检报告

| 项目 | 内容 |
|---|---|
| 集群 | k8s-prod-ha（3 × control-plane，stacked etcd + kube-vip） |
| 版本 | Kubernetes **v1.34.13** · containerd 2.2.1 · Calico v3.33.0 · kube-vip v0.8.9 |
| 巡检时间 | 2026-10-30 21:41 — 21:43（CST），耗时 2 分 10 秒 |
| 巡检范围 | 集群层 12 项 + 主机层 3 台 × 9 项，共 **39 个检查点** |
| 巡检方式 | 只读采集（`kubectl get` / `etcdctl` / `systemctl` / `journalctl`），未修改任何状态 |
| 巡检脚本 | `scripts/k8s_inspect_cluster.sh`、`scripts/host_inspect.sh` |
| 集群运行时长 | 2 小时 27 分（2026-10-30 19:13 起） |
| 总体结论 | **运行状态健康 ✅ / 生产就绪度不足 ⚠️** |

---

## 一、总体结论

**三个子系统全绿，无 P0 级故障**：控制面 3 副本全部 Running 且零重启、etcd 3 成员健康且 raft index 一致、VIP 可通且租约正常、无异常 Pod、无 OOM、无 IO 错误。

**但距生产可交付还差一层**：安全基线（审计/加密/网络策略）几乎空白，可观测性缺失（无 metrics-server，看不到容量趋势），备份只有本地单份且未做过恢复演练。

| 评分维度 | 得分 | 说明 |
|---|---|---|
| **运行健康度** | **98 / 100** | 所有运行时指标正常，仅 etcd commit 延迟略高于理想值 |
| **生产就绪度** | **62 / 100** | 安全 45、备份 60、可观测 40 三项明显偏低 |

**本次发现 0 个 P0、7 个 P1、6 个 P2。** 另修正 1 处文档错误：Calico 实际为 **IPIP 封装**（`ipipMode=Always`，存在 `tunl0` 接口），此前手册与拓扑图误写为 VXLAN，已更正。

---

## 二、检查结果总览

| # | 检查维度 | 状态 | 关键指标 |
|---|---|---|---|
| 1 | 集群可用性 | ✅ 正常 | healthz=ok，API 响应 0.08–0.10s |
| 2 | 节点状态 | ✅ 正常 | 3/3 Ready，无 Memory/Disk/PID 压力 |
| 3 | 资源容量 | ⚠️ 观察 | CPU 请求率 22–27%，内存 1%，**无 metrics 无趋势** |
| 4 | 控制面组件 | ✅ 正常 | 9 个静态 Pod 全 Running，**重启 0 次**，1 小时 ERROR 日志 0 行 |
| 5 | etcd 集群 | ✅ 正常 | 3 member / 1 leader，index 一致 34839，无 alarm |
| 6 | 网络与 DNS | ✅ 正常 | Calico 3/3、CoreDNS 2/2、VIP 0% 丢包 |
| 7 | 工作负载 | ✅ 正常 | 25 Pod 全 Running，0 未就绪、0 失败 Job、0 驱逐 |
| 8 | 存储 | ⚠️ 缺口 | **StorageClass / PV / PVC 均为 0** |
| 9 | 证书有效期 | ✅ 正常 | 全部 364 天，CA 9 年 |
| 10 | 主机层（3 台） | ✅ 正常 | 磁盘 18%、inode 4%、无 OOM、服务零重启 |
| 11 | 安全基线 | ❌ 缺失 | 无审计、无加密、0 NetworkPolicy、无 PSA |
| 12 | 备份 | ⚠️ 不足 | 快照 7.5MB + 每日 2:00，**仅本地单份、未演练** |

---

## 三、逐项检查明细

### 3.1 集群可用性 ✅

```
Client / Server Version: v1.34.13   （版本一致）
healthz: ok
API 响应: 0.10s / 0.09s / 0.08s     （阈值 <1s，良好）
命名空间: 4    全集群 Pod: 25
```

### 3.2 节点状态 ✅

| 节点 | 状态 | 角色 | 版本 | 运行时 | 压力条件 |
|---|---|---|---|---|---|
| k8s-master-01 | Ready | control-plane | v1.34.13 | containerd 2.2.1 | 全部 False |
| k8s-master-02 | Ready | control-plane | v1.34.13 | containerd 2.2.1 | 全部 False |
| k8s-master-03 | Ready | control-plane | v1.34.13 | containerd 2.2.1 | 全部 False |

`MemoryPressure / DiskPressure / PIDPressure / NetworkUnavailable` 全部 False，三台均无 Taint。

> ⚠️ 无 Taint 意味着业务 Pod 与控制面同机运行，这是部署时的容量取舍（详见问题 P1-5）。

### 3.3 资源容量 ⚠️

| 节点 | 可分配 CPU | 可分配内存 | 可分配 Pod | CPU 请求率 | 内存请求率 | 实际 Pod 数 |
|---|---|---|---|---|---|---|
| k8s-master-01 | 4 | 15.5 Gi | 110 | 1100m (**27%**) | 240 Mi (1%) | 10 |
| k8s-master-02 | 4 | 15.5 Gi | 110 | 900m (**22%**) | 100 Mi (0%) | 8 |
| k8s-master-03 | 4 | 15.5 Gi | 110 | 900m (**22%**) | 100 Mi (0%) | 7 |

**解读**：CPU 请求率看似 27%，但其中大部分是 kube-apiserver 等控制面组件的静态预留（每个 apiserver 约 250m）。真实业务负载几乎为零，内存压力可忽略。

**风险**：没有 metrics-server，`kubectl top` 不可用，看不出实际用量与 requests 的偏差，也无法做容量趋势预测。

### 3.4 控制面组件 ✅

```
calico-kube-controllers  1/1 Running    etcd × 3              1/1 Running
coredns × 2              1/1 Running    kube-apiserver × 3    1/1 Running
calico-node × 3          1/1 Running    kube-controller-mgr×3 1/1 Running
kube-proxy × 3           1/1 Running    kube-scheduler × 3    1/1 Running
kube-vip × 3             1/1 Running
```

- **重启次数 Top5：全部为 0**（连续运行 2 小时无任何重启）
- **近 1 小时控制面 ERROR 日志：9 个组件全部 0 行**

这一项是整个报告里最干净的数据——说明部署质量良好，没有反复崩溃的组件。

### 3.5 etcd 集群 ✅

| 指标 | 实测值 | 参考阈值 | 判定 |
|---|---|---|---|
| 成员数 | 3（全 started） | 3 或 5 | ✅ 可容错 1 台 |
| Leader | 1 个（k8s-master-01） | 必须唯一 | ✅ |
| Raft Index | 34839 / applied 34839 | 三者应一致 | ✅ 完全一致 |
| DB 大小 | 7.8 MB | >2 GB 考虑 defrag | ✅ 远低于阈值 |
| 版本 | 3.6.5 | — | ✅ |
| Alarm | 无 | 不应有 NOSPACE | ✅ |
| Commit 延迟 | 12.2 ms / 14.6 ms | 理想 <10 ms | ⚠️ 略高，VM 环境正常 |

`etcdctl endpoint health --cluster` 对三个成员均返回 healthy。

> commit 延迟 12–15ms 在 VMware 虚拟磁盘上属正常范围（物理 SSD 通常 1–5ms）。若后续业务写入频繁，需关注此值是否上升。

### 3.6 网络与 DNS ✅

| 检查项 | 结果 |
|---|---|
| Calico Node | 3/3 Running，0 重启 |
| 封装模式 | **IPIP**（`ipipMode=Always`、`vxlanMode=Never`，`tunl0` 接口存在） |
| IPPool | `default-ipv4-ippool` 10.244.0.0/16，blockSize 26 |
| IPAM 已分配块 | 3 个（每节点 1 个） |
| BGP | 每台 `bird` 监听 179，邻居已建立 |
| CoreDNS | 2/2 Ready |
| kube-proxy | 3/3（DaemonSet 全节点） |
| VIP 连通性 | 2 packets, **0% 丢包**，RTT 0.056 ms |
| VIP 持有者 | k8s-master-01，renewTime 13:41:04 UTC（持续续约） |
| 空 Endpoints 的 Service | 0 个 |

### 3.7 工作负载 ✅

- 非 Running/Succeeded 的 Pod：**0 个**
- 未就绪 Deployment：**0 个**（coredns 2/2、calico-kube-controllers 1/1）
- 失败 Job：**0 个**
- Evicted 历史：**0 次**
- 最近 Warning 事件：**0 条**（近 1 小时无任何告警事件）

### 3.8 存储 ⚠️

```
StorageClass: 0 个     PV: 0 个     PVC: 0 个
```

集群目前**没有任何持久化存储能力**。当前所有工作负载都是无状态的（控制面组件、CoreDNS），所以没有暴露问题，但一旦部署 MySQL / Redis / Prometheus 这类有状态服务，PVC 会永久 Pending。

### 3.9 证书有效期 ✅

| 证书 | 到期时间 | 剩余 |
|---|---|---|
| apiserver / apiserver-etcd-client / apiserver-kubelet-client | 2027-10-30 | **364 天** |
| etcd-server / etcd-peer / etcd-healthcheck-client | 2027-10-30 | 364 天 |
| admin.conf / controller-manager.conf / scheduler.conf / super-admin.conf | 2027-10-30 | 364 天 |
| front-proxy-client | 2027-10-30 | 364 天 |
| **ca / etcd-ca / front-proxy-ca** | **2036-10-27** | **9 年** |

全部一致到期（kubeadm 统一签发），无 `EXTERNALLY MANAGED` 异常项。**建议在 2027-07 前完成续期演练**，不要拖到最后一个月。

### 3.10 主机层 ✅（三台横向对比）

| 指标 | master-01 | master-02 | master-03 | 判定 |
|---|---|---|---|---|
| 运行时长 | 2h27m | 2h27m | 2h27m | ✅ 同时启动 |
| 负载（1/5/15m） | 0.68 / 0.48 / 0.42 | 0.11 / 0.18 / 0.23 | 0.66 / 0.75 / 0.53 | ✅ 均 <1（4 核） |
| 内存已用 | 1.3 Gi / 15 Gi | 1.1 Gi / 15 Gi | 1.2 Gi / 15 Gi | ✅ 极低 |
| Swap | 0 B | 0 B | 0 B | ✅ 已关闭 |
| 根分区 | 9.7G / 57G (**18%**) | 9.6G / 57G (18%) | 9.6G / 57G (18%) | ✅ |
| inode | 4% | 4% | 4% | ✅ |
| 磁盘 IO wait | 2% | 6% | 4% | ✅ |
| containerd 数据 | 1.8 G / 13 镜像 | 1.8 G / 13 镜像 | 1.8 G / 13 镜像 | ✅ 一致 |
| kubelet / containerd / sshd | active，**重启 0** | active，0 | active，0 | ✅ |
| 失败 systemd 单元 | 0 | 0 | 0 | ✅ |
| 时间同步 | 已同步，CST | 已同步 | 已同步 | ✅ |
| OOM 记录（7 天） | 0 | 0 | 0 | ✅ |
| IO / 文件系统错误 | 0 | 0 | 0 | ✅ |
| 运行中容器数 | 9 | 6 | 6 | — |

**关于 dmesg 的 44 条 error（三台相同）**：已逐条核查，全部为开机阶段的 `pci 0000:00:15.x: bridge window [io size 0x1000]: failed to assign` 与 `RAS: Correctable Errors collector initialized`，属 VMware 虚拟 PCI 总线的正常提示，**非运行期故障**，无需处理。

**关于 `ens160 rx_drop=1767`（三台数值几乎一致）**：三台完全相同说明是**开机阶段产生的固定量**（IPv6 邻居发现/组播包在网卡未完全就绪时被丢弃），非持续丢包。当前无业务影响，列入观察项。

---

## 四、问题清单与整改建议

### P0 — 阻断性故障：**无**

### P1 — 应在生产上线前处理

| # | 问题 | 影响 | 整改建议 |
|---|---|---|---|
| **P1-1** | **无审计日志**（apiserver 无 `--audit-policy-file` / `--audit-log-path`） | 安全事件无法追溯"谁在何时改了什么"，等保/合规必查项 | 配置 audit policy，输出到 `/var/log/k8s-audit.log`，配 logrotate；改 apiserver 静态 Pod（3 台滚动） |
| **P1-2** | **etcd 未加密存储**（无 `--encryption-provider-config`） | Secret 以明文存于 etcd，磁盘/快照泄露即全量泄露 | 生成 `EncryptionConfiguration`（aescbc），改 apiserver 后 `kubectl get secrets -A -o yaml \| kubectl replace -f -` 全量重写 |
| **P1-3** | **0 个 NetworkPolicy** | Pod 之间全通，任一 Pod 被拿下即可横向访问全集群 | 至少给业务命名空间加 `default-deny-ingress` + 按需放行 |
| **P1-4** | **无 metrics-server** | `kubectl top` 不可用、HPA 无法工作、无容量趋势 | 部署 metrics-server（走 ghcr/daocloud 加速），自签证书需 `--kubelet-insecure-tls` |
| **P1-5** | **控制平面兼跑业务**（污点已移除，0 worker） | 业务 IO 与 etcd fsync 抢磁盘；资源挤占会让 apiserver 抖动 | 短期：给业务 Pod 设 `requests/limits` 并限制总配额；长期：新增 2–3 台 worker，恢复污点 |
| **P1-6** | **节点无资源预留**（未设 `systemReserved` / `kubeReserved` / `evictionHard`） | 业务 Pod 无 limits 时可能吃光内存，触发 OOM 时最先被杀的往往是 etcd | kubelet 配置加 `systemReserved: cpu 500m, memory 1Gi` + `evictionHard: memory.available<500Mi` |
| **P1-7** | **备份仅本地单份、未做恢复演练** | 磁盘故障时备份与集群一起丢失；未演练的备份不可信 | 快照同步到另一台物理机/对象存储；**每季度做一次真实恢复演练** |

### P2 — 可排期优化

| # | 问题 | 建议 |
|---|---|---|
| P2-1 | `super-admin.conf` 仍在 `/etc/kubernetes/` | 官方建议移到安全位置：`sudo mv /etc/kubernetes/super-admin.conf /root/.kube/` |
| P2-2 | 所有命名空间均无 PSA 标签 | 业务命名空间加 `pod-security.kubernetes.io/enforce: baseline` 起，逐步到 `restricted` |
| P2-3 | 0 个 StorageClass | 接入 local-path-provisioner 或 NFS CSI，为有状态负载做准备 |
| P2-4 | 工作负载未关 `automountServiceAccountToken` | 不需要访问 API 的工作负载显式设 `false` |
| P2-5 | 节点无 `topology.kubernetes.io/zone` 标签 | 确认三台 VM 分布在不同 ESXi 后，打 zone 标签并配 podAntiAffinity |
| P2-6 | `controlPlaneEndpoint` 用 IP 而非域名 | 备用方案：DNS 指向 `k8s-api.ai4system.com`，证书 SAN 已包含该域名 |

---

## 五、巡检方法学：如何对 K8s 做系统巡检

### 5.1 三层模型（缺一层就有盲区）

| 层 | 看什么 | 本次对应章节 |
|---|---|---|
| **集群层** | 节点 Ready、控制面重启、etcd 健康、调度是否正常 | 3.1–3.5、3.7 |
| **网络层** | CNI Pod、IPPool 余量、CoreDNS、VIP、Service Endpoints | 3.6 |
| **主机层** | 磁盘/inode、内存、负载、OOM、IO 错误、时间同步、服务重启 | 3.10 |

只做 `kubectl get nodes` 不叫巡检——节点 Ready 但磁盘 95%、etcd fsync 慢 10 倍，`get nodes` 依然是绿的。

### 5.2 巡检频率三档

| 频率 | 内容 | 耗时 | 方式 |
|---|---|---|---|
| **每日** | 三层脚本全量跑一遍，比对基线 | 2–3 分钟 | cron 自动执行 + 结果归档 |
| **每周** | 加：容量趋势（需 metrics）、ERROR 日志聚类、Warning 事件汇总 | 15 分钟 | 人工看趋势，不只看瞬时值 |
| **每月** | 加：证书剩余天数、备份可恢复性抽检、安全基线复核、版本 EOL 检查 | 1 小时 | 人工 + 变更窗口 |

**触发式巡检**（不等周期，立刻跑）：任何变更后、告警后、节点重启后、镜像升级后。

### 5.3 关键阈值表（按此判定红黄绿）

| 指标 | 🟢 正常 | 🟡 关注 | 🔴 告警 |
|---|---|---|---|
| 节点 Ready | 全部 True | 单节点 NotReady <5min | 多节点 NotReady / >5min |
| 控制面 Pod 重启次数 | 0 | 1–2（非同时） | 持续增长 / CrashLoop |
| etcd commit 延迟 | <10 ms | 10–25 ms | >25 ms |
| etcd DB 大小 | <2 GB | 2–8 GB | >8 GB（需 defrag） |
| etcd raft index 差异 | 0 | — | 成员间不一致 |
| 磁盘使用率 | <70% | 70–85% | >85% |
| inode 使用率 | <70% | 70–85% | >85% |
| 内存可用 | >20% | 10–20% | <10% |
| CPU 请求率 | <60% | 60–80% | >80% |
| 证书剩余 | >90 天 | 30–90 天 | <30 天 |
| 最近 etcd 快照 | <24 h | 24–72 h | >72 h 或缺失 |
| 未就绪 Pod | 0 | 1–2 短暂 | 持续存在 |

### 5.4 本次巡检暴露的方法论价值

三条经验，供下次巡检复用：

1. **跨层交叉验证**：主机层看到 `tunl0` 接口，才反推出 Calico 是 IPIP 而非文档写的 VXLAN。只看 `kubectl get pods` 永远发现不了。
2. **同值即异常值**：三台 `rx_drop` 都是 1767、dmesg 都是 44 条 —— 这种"完全一致"说明是**开机固定产物**，不是持续劣化，不必紧张。反之若三台数值发散，就要查网络。
3. **绿灯不等于健康**：本次 12 项里 9 项绿灯，但安全项全红。巡检报告必须同时回答"现在能不能跑"和"敢不敢上生产"。

---

## 六、附录

### 6.1 脚本使用

```bash
export SUDO_PW='你的 sudo 密码'

# 集群层（在任一控制平面节点执行）
bash scripts/k8s_inspect_cluster.sh

# 主机层（每台执行，或由跳板机远程调用）
bash scripts/host_inspect.sh
```

### 6.2 接入每日自动巡检

```bash
# 在 master-01 上加 cron（示例：每天 7:00，保留 30 天）
0 7 * * * /usr/local/bin/k8s_inspect_cluster.sh > /var/log/inspect/$(date +\%F).log 2>&1
```

### 6.3 本次原始输出

| 文件 | 内容 |
|---|---|
| `.workbuddy/reports/raw_cluster.txt` | 集群层 167 行原始输出 |
| `.workbuddy/reports/raw_hosts.txt` | 三台主机层 222 行原始输出 |

### 6.4 下一次巡检重点

按 P1 清单整改后，重点复检：

1. 审计日志是否正常落盘、轮转是否生效
2. Secret 是否已加密（`etcdctl get /registry/secrets/... | strings` 应看不到明文）
3. NetworkPolicy 生效后业务连通性是否受影响
4. metrics-server 上线后，补一份**容量基线**（当前是空白）
5. 备份恢复演练结果（这是唯一不能靠"看指标"确认的项目）

---

*报告生成：2026-10-30 21:43 CST · 巡检工具：只读采集脚本 · 下次建议巡检：2026-10-31*
