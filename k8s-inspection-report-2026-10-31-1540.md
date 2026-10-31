# Kubernetes 集群巡检报告（第三次 · 故障巡检）

| 项目 | 内容 |
|---|---|
| 集群 | k8s-prod-ha（3 × control-plane，stacked etcd + kube-vip） |
| 版本 | Kubernetes **v1.34.13** · containerd 2.2.1 · Calico v3.33.0 · kube-vip v0.8.9 |
| 巡检时间 | 2026-10-31 15:27–15:33（CST） |
| 比对基线 | 2026-10-30 23:49（第二次巡检） |
| 巡检方式 | SSH（lumz@192.168.1.102/103）+ 只读采集脚本；**master-01 SSH/ICMP/ARP 全部不可达，未能登录** |
| 原始输出 | `.workbuddy/reports/raw_cluster.txt`（166 行）· `raw_hosts.txt`（156 行，缺 01） |
| 总体结论 | **集群降级运行：master-01 失联，2/3 etcd 保 quorum，VIP 已漂移，API 正常；Kuboard 因数据库单点而不可用** |

---

## 一、总体结论

**控制面从 3 节点降到 2 节点，但集群没有失去可用性。**

- master-01（192.168.1.101）在 **15:17:56** 停止上报 kubelet 状态，**15:22:35** 被判 NotReady 并打 `unreachable` 污点（NoSchedule + NoExecute）。
- **VIP 已自动漂移**：15:21:35 由 master-01 转到 **k8s-master-03**，租约持续续约，`https://192.168.1.100:6443` 访问正常（healthz ok，延迟 0.08s×3）。
- **etcd 2/3 存活**：.102/.103 healthy，commit 延迟 11.5–11.7ms，DB 仍 7.8MB，无 alarm；.103 为新 leader（raft term 3，index 341566）。
- **受影响业务只有一个**：Kuboard 的 MariaDB Pod 被驱逐后无法重新调度（PV hostPath 钉在 master-01），Kuboard Web 不可用；**Headlamp 正常（HTTP 200）**。
- 已追加一份**手工 etcd 快照**（`/var/backups/etcd/etcd-snap-20261031-1532.db`，7.5MB，hash `68640bfc`，rev 277322），因为原备份 cron 只配在 master-01 上，随主机一起停了。

## 二、故障时间线（CST）

| 时间 | 事件 | 证据 |
|---|---|---|
| **15:17:56** | master-01 最后一次上报节点状态 | `lastHeartbeatTime=2026-10-31T07:17:56Z` |
| ~15:17–15:21 | 主机彻底离线（ARP 都不应答） | 从 .102/.103 `ip neigh` 显示 `192.168.1.101 INCOMPLETE`，ping 返回 `+3 errors` |
| **15:21:35** | kube-vip 在 master-03 抢到租约，VIP 漂移完成 | kube-vip 日志 `successfully acquired lease kube-system/plndr-cp-lock` |
| **15:21:45** | apiserver 侧 etcd 连接重连（选主窗口告警） | `kube-apiserver-k8s-master-02` 日志 `dial tcp 127.0.0.1:2379: operation was canceled` |
| **15:22:35** | 节点转 NotReady，打 unreachable 污点 | node conditions `Kubelet stopped posting node status` |
| **15:27:36** | NoExecute 驱逐开始：calico-kube-controllers 重建到 .103；kuboard-db 被驱逐但调度失败 | events `TaintManagerEviction` / `FailedScheduling` |
| **15:30:25** | kuboard 就绪探针失败 → Service 无端点 | events `Unhealthy kuboard-695ff746b7-9hnqr` |
| **15:32:08** | 手工 etcd 快照完成并校验 | `etcdutl snapshot status` → 476 keys / 7.8MB / 3.6.0 |

## 三、当前状态

### 3.1 节点

| 节点 | 状态 | 说明 |
|---|---|---|
| k8s-master-01 | **NotReady（Unknown）** | 主机层完全不可达：ping 丢包 100%、TCP 22 超时、ARP INCOMPLETE。疑为关机/内核挂死/网卡失效 |
| k8s-master-02 | Ready | 负载 0.45 / 内存 15Gi 用 1.4Gi（14Gi 可用）/ 磁盘 21% / kubelet 19h 零重启 |
| k8s-master-03 | Ready | 负载 0.19 / 内存 15Gi 用 1.9Gi / 磁盘 20% / **持有 VIP 192.168.1.100** |

### 3.2 控制面与 etcd

| 指标 | 基线（23:49） | 本次 | 判定 |
|---|---|---|---|
| API healthz | ok | ok（0.08s×3） | ✅ 正常 |
| 节点 Ready | 3/3 | **2/3** | ❌ 降级 |
| etcd 成员 | 3/3 started | 3 成员，**2 healthy / 1 no route to host** | ⚠️ quorum 保住（2/3） |
| etcd raft index | 71706 | 341566（.103 leader） | ✅ 正常增长 |
| etcd DB / alarm | 7.8MB / 无 | 7.8MB / 无 | ✅ 无膨胀、无 NOSPACE |
| etcd commit 延迟 | 11.3 / 11.7ms | 11.5 / 11.7ms | ✅ 未受影响 |
| VIP 持有者 | master-01 | **master-03** | ⚠️ 已漂移，工作正常 |
| apiserver ERROR 日志（1h） | 0 | .102：15 行（均为 15:21 选主窗口的 etcd 重连） | ⚠️ 已自愈 |

### 3.3 工作负载影响

| 对象 | 状态 | 影响 |
|---|---|---|
| `kuboard/kuboard-db-…-5dwf4` | Terminating（卡在失联节点） | 旧副本无法删除，等节点回归 |
| `kuboard/kuboard-db-…-cmnvj` | **Pending** | 无法调度：`1 node had untolerated taint, 2 nodes didn't match node affinity`（PV hostPath 钉 master-01） |
| `kuboard/kuboard-…-9hnqr` | 1/1 Running 但 Ready 失败 | 连不上 DB → `:30080` 访问超时（**面板不可用**） |
| `headlamp/headlamp-…-b7swk` | 1/1 Running | `:30081` 返回 200，**可正常使用** |
| `calico-kube-controllers` | 已重建到 .103（2m 内完成） | 无影响 |
| CoreDNS / kube-proxy / calico-node | .102/.103 上全部 Running | 集群内解析与跨节点网络正常 |
| 其余系统性 Pod | 全 Running，重启 0 | 无影响 |

> 全集群 30 个 Pod，异常 3 个（上表前三行），其余全 Running。

### 3.4 主机层（.102 / .103）

| 项 | master-02 | master-03 |
|---|---|---|
| uptime | 20h16m | 20h16m |
| 内存 | 1.4Gi / 15Gi（14Gi 可用） | 1.9Gi / 15Gi（13Gi 可用） |
| 根分区 | 12G / 57G（21%） | 11G / 57G（20%） |
| inode | 4% | 4% |
| OOM（7 天） | 0 | 0 |
| IO / 文件系统错误 | 0 | 0 |
| kubelet / containerd / sshd | active，重启 0 | active，重启 0 |
| 失败单元 | 0 | 0 |
| 时间同步 | NTP active，已同步 | 同 |
| conntrack | 769 / 131072 | 967 / 131072 |

## 四、本次已处置

| 动作 | 结果 |
|---|---|
| 切换集群层巡检执行节点到 master-02 | 巡检脚本改为容错版（不可达节点记录后跳过），已落盘 `raw_*.txt` |
| **补一份手工 etcd 快照** | `k8s-master-02:/var/backups/etcd/etcd-snap-20261031-1532.db`（7.5MB，600 root，`etcdutl snapshot status` 校验通过：hash 68640bfc / rev 277322 / 476 keys）；这是当前唯一一份「包含 master-01 失联前数据」的最新快照 |
| 未做任何变更性操作 | 未删节点、未删 etcd 成员、未 drain、未重启任何服务 |

## 五、待处置（按优先级）

### P0-1 恢复 master-01（需在 VMware 控制台操作）

我这边只有 SSH 通道，主机 ARP 都不应答，**已经没有远程手段**，必须在虚拟化平台侧处理：

1. 在 VMware（宿主）里确认该 VM 电源状态：**已关机 → 直接开机**；**运行中但无响应 → 强制关机后开机**
2. 开机后观察引导是否正常（若内核 panic 或磁盘异常，控制台会直接显示）
3. 起来后按顺序验证：

```bash
ping -c2 192.168.1.101 && ssh lumz@192.168.1.101 'systemctl is-active kubelet containerd'
kubectl get nodes -w                       # 期望 1–2 分钟内 master-01 变 Ready
kubectl -n kube-system get pods -o wide | grep master-01   # 静态 Pod 应全部 Running
```

4. 确认 etcd 成员自愈（**不要 remove member，数据还在，会自动追平**）：

```bash
# 在 .102 或 .103 上（容器内 etcdctl）
kubectl -n kube-system get pods -o wide | grep etcd        # 三个都 Running 才算齐
# endpoint status 里 master-01 的 RAFT INDEX 应逐步追上 .102/.103，ERRORS 为空
```

5. 最后确认 Kuboard 自动恢复：

```bash
kubectl -n kuboard get pods,pvc          # Pending 的 DB 应调度到 .101，PVC 重新 Bound
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.100:30080/   # 期望 200
```

> VIP 不必迁回 master-01：kube-vip 会稳定在 .103，多一次漂移反而多一次风险。

### P0-2 备份链已断（已临时补一份）

- 原 `etcd-backup` cron **只存在于 master-01**，`/var/backups/etcd` 在 .102/.103 上根本不存在 → 主机一挂，每日 02:00 备份就没了。
- 本次已手工补一份到 .102。**节点恢复后建议把备份脚本铺到三台**（各自备份本地 etcd，或至少 .102/.103 各一份），并把「快照异地/异机存放」列入整改。

### P1 Kuboard 数据库单点（本次故障暴露的设计缺陷）

- `kuboard-db` 用 hostPath PV + `nodeSelector: k8s-master-01`，节点一失联就永久 Pending，面板整体不可用。
- 三个选项：
  1. **接受降级**（推荐给实验环境）：面板不可用时用 Headlamp，节点恢复即自愈；
  2. 把 PV 改成 `local` + 允许在 .102/.103 调度（仍是单副本，只是多一个候选节点，需要迁数据）；
  3. 彻底换掉 Kuboard，只留 Headlamp（无状态、无 DB，天然不受节点故障影响）。

### P1 期间的操作红线（2/3 etcd 状态下）

- **禁止** drain / reboot / 关机 master-02、master-03（再掉一台即失去 quorum，集群只读甚至不可用）
- **禁止** etcd defrag、成员变更、快照恢复演练
- **禁止** 版本升级、控制面静态 Pod 批量改动（确需改动，一次只动一台且改前确认三成员健康）
- 集群内可正常创建/删除业务 Pod（apiserver 与调度器均正常）

## 六、观察项（非告警）

1. **ens160 rx_drop：3306 → 14588/14590**（.102/.103，高度一致）。较上次 +1.1 万，判断与失联节点的 ARP 反复解析、kube-vip 每 3 秒 Gratuitous ARP 有关，无业务丢包（rx_err=0），节点恢复后应停止增长——若继续增长再排查。
2. **CoreDNS Pod 年龄 15m**：为失联后重建（原副本曾在 .101），当前 2/2 就绪，解析正常。
3. **dmesg 44 条 error/warn**：.102/.103 一致，为开机阶段 VMware 设备提示，与基线相同，非运行期故障。

## 七、遗留问题清单（沿用基线，无新增）

**P1（7 项，仍未整改）**：无审计日志 · etcd 未加密 · 0 NetworkPolicy · 无 metrics-server · 控制面兼跑业务 · 节点无资源预留 · 备份仅本地单份未演练（本次故障已证明该风险真实存在）。

**P2（延续）**：super-admin.conf · 无 PSA 标签（kuboard 清单已加 baseline，集群默认未设）· 0 StorageClass · automountServiceAccountToken · 无 zone 标签 · controlPlaneEndpoint 用 IP。

**本次新增认知（建议纳入 P1）**：**单节点故障会连带面板类单点服务不可用**——凡是用 hostPath/本地卷承载状态的组件，都应显式标注「依赖节点 X」，故障时能一眼看出影响面。

## 八、结论一句话

**master-01 于 15:17 整机失联，集群靠 2/3 etcd 与 VIP 漂移维持可用，API、DNS、网络、Headlamp 均正常；唯一受损的是钉在该节点上的 Kuboard 数据库；下一步只能在 VMware 侧把 master-01 开回来，期间严禁再动另外两台控制面。**

---

*报告生成：2026-10-31 15:40 CST · 下次动作：master-01 恢复后 10 分钟内复检 etcd 追平与 Kuboard 自愈*
