# 从集群移除 k8s-worker-05（192.168.1.105）操作计划

> 编写时间：2026-10-31 17:45 CST · 集群：k8s-prod-ha（v1.34.13，Calico v3.33.0 IPIP）· 当前 5 节点
> 目标：把 `k8s-worker-05` 干净地移出集群，不留 Calico IPAM / CNI / iptables 残留
>
> **状态：已于 2026-10-31 17:45–17:55 按场景 A 执行完毕** —— `.105` 已移除并改名 `k8s-worker-02` 重新加入，集群 5 节点全 Ready。执行结果与实测坑见第 8 节；阶段 4/5 的命令已按实测修正。

---

## 0. 先确认一件事：踢出之后的用途

这一步决定最后两个阶段怎么做，其余步骤完全相同。

| 场景 | 后续动作 | 建议 |
|---|---|---|
| **A. 改名后重新加入**（例如统一为 `k8s-worker-02`） | reset 后 `hostnamectl set-hostname`，保留 kubelet/containerd，重新 join | 最可能的情况：`.104` 是 `worker-01`、`.105` 是 `worker-05`，序号规则不统一 |
| **B. 彻底退役**（机器另作他用 / 长期关机） | reset 后卸载 kubelet/kubeadm/kubectl，可选卸载 containerd，释放 1.8G 镜像 | 若只是暂时不用，建议选 A 的保留式 reset |

**两种场景共用阶段 1–5，只在阶段 6 分叉。**

---

## 1. 现状盘点（2026-10-31 17:43 实测）

### 1.1 节点上的负载

```
kube-system   calico-node-vb5s5   1/1   Running   k8s-worker-05
kube-system   kube-proxy-lcb42    1/1   Running   k8s-worker-05
```

**只有 2 个 DaemonSet Pod，没有任何业务 Pod。** drain 实际不会驱逐任何东西，只是把节点标记为不可调度。

### 1.2 关联资源

| 资源 | 实测状态 | 移出时的处理 |
|---|---|---|
| PV / PVC | 无绑定在 .105（唯一的 `kuboard-mariadb-pv` 在 master-01） | 无需迁移 |
| blockaffinity | `k8s-worker-05-10-244-55-192-26`（CIDR `10.244.55.192/26`） | **删节点后可能残留，需手工清** |
| ipamblock | 1 个（对应上述块） | 随 blockaffinity 回收，残留则手工删 |
| CSINode | 存在但 `DRIVERS=0` | 随节点自动回收 |
| node lease | `kube-node-lease/k8s-worker-05`，正常续约 | 随节点自动回收 |
| node 专属 Secret | 无 | 无需处理 |
| taints / unschedulable | 无污点、可调度 | cordon 后加 unschedulable |

### 1.3 节点本地残留（reset 后需确认清理）

| 项 | 现状 |
|---|---|
| kubelet | `active` + `enabled` |
| `/etc/kubernetes/` | `kubelet.conf`、`pki/`、`manifests/`（worker 形态，20K） |
| `/etc/cni/net.d/` | `10-calico.conflist`、`calico-kubeconfig` |
| 网络接口 | `tunl0`（IPIP），`inet 10.244.55.192/32` |
| 路由 | 4 条 `10.244.x/26 via tunl0` + 1 条 `blackhole 10.244.55.192/26` |
| iptables | nat 表 15 条 `cali-*` 链 |
| containerd 镜像 | **1.8G**（`/var/lib/containerd`） |

---

## 2. 影响评估

| 维度 | 影响 |
|---|---|
| 集群容量 | 5 节点 → **4 节点**（3 control-plane + 1 worker），损失 8C / 31G / 110 pods 可分配量 |
| 业务可用性 | **零影响** —— 该节点无业务 Pod，无 PV |
| etcd / 控制面 | **零影响** —— worker 不参与 etcd，quorum 仍 3/3 |
| 网络 | Calico 少一个 `/26` 块（`10.244.55.192/26`，64 个地址），IPPool `10.244.0.0/16` 其余部分不受影响 |
| Kuboard / Headlamp | **零影响**（都钉在 master 节点） |
| 可回滚性 | 高 —— 重新 join 约 3 分钟，无需重建机器 |

**结论：这是低风险操作。** 真正的坑不在"删节点"，而在**删完之后的残留清理**（Calico IPAM 块、iptables 链、tunl0 路由），这些不清理的话机器复用时会出怪问题。

---

## 3. 操作步骤（5 阶段，约 8 分钟）

```
阶段1 预检（只读）                           1 min
阶段2 cordon（停止调度）                     10 s
阶段3 drain（排空，本环境无 Pod 可驱逐）      20 s
阶段4 节点侧 kubeadm reset + 本地清理         2 min
阶段5 平台侧 delete node + Calico IPAM 清理    2 min
阶段6 分叉：A 改名重加 / B 彻底退役           2 min
```

### 阶段 1：预检（只读，不改任何状态）

在 master 上执行：

```bash
# 1) 确认节点上没有业务 Pod（应只剩 calico-node / kube-proxy）
kubectl get pods -A -o wide --field-selector spec.nodeName=k8s-worker-05

# 2) 确认没有 PV 钉在该节点
kubectl get pv -o json | jq -r '.items[] | select(.spec.nodeAffinity!=null) | "\(.metadata.name) \(.spec.nodeAffinity)"'

# 3) 记录当前 IPAM 块（后面要对比是否清干净）
kubectl get blockaffinities.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,NODE:.spec.node, CIDR:.spec.cidr | grep worker-05

# 4) 基线：当前节点数
kubectl get nodes -o wide
```

> 若第 1 步出现非 DaemonSet 的 Pod，先单独处理（`kubectl drain` 会驱逐它，但要确认它属于 Deployment/StatefulSet 且有副本能在别处重建）。

### 阶段 2：停止调度

```bash
kubectl cordon k8s-worker-05
kubectl get node k8s-worker-05 -o jsonpath='{.spec.unschedulable}'; echo   # 期望 true
```

作用：立刻阻止新 Pod 调度到该节点。此时已有的 Pod 不受影响。

### 阶段 3：排空

```bash
kubectl drain k8s-worker-05 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --timeout=120s
```

各参数的作用（缺一个就可能卡住）：

| 参数 | 原因 |
|---|---|
| `--ignore-daemonsets` | 节点上有 calico-node / kube-proxy（DS），不加会直接报错退出。加上后 DS Pod **不会被驱逐**（这是期望行为） |
| `--delete-emptydir-data` | v1.34 起 emptyDir 数据需显式确认，否则报错 |
| `--force` | 允许删除无控制器管理的裸 Pod（本环境无，但加上避免意外卡住） |

本环境预期输出：`node/k8s-worker-05 already cordoned` + `node/k8s-worker-05 drained`（**没有 Pod 被驱逐**）。

### 阶段 4：节点侧清理

**顺序很重要：先 reset 再 delete node。** 反过来的话 kubelet 还在跑，会不停尝试连接已删除的节点身份，日志刷错且可能重新注册出乱七八糟的状态。

在 **k8s-worker-05** 上执行：

```bash
# 4.1 官方 reset：停 kubelet、删 /etc/kubernetes、清 kubelet 目录
sudo kubeadm reset -f

# 4.2 等 Calico 释放 IP 分配（约 30 秒），再做后续
sleep 30

# 4.3 清残留容器（reset 偶尔留 sandbox）
sudo crictl ps -aq | xargs -r crictl rm -f
sudo crictl pods -q | xargs -r crictl rmp -f

# 4.4 清 CNI 残留
sudo rm -rf /etc/cni/net.d/* /var/lib/cni/

# 4.5 先清 Calico 路由（proto 80）——不先清的话 tunl0 删了会被立刻重建
sudo ip route flush proto 80

# 4.6 再摘 tunl0 上的 Calico /32 地址，最后删设备
sudo ip addr del 10.244.55.192/32 dev tunl0 2>/dev/null
sudo ip link set tunl0 down 2>/dev/null
sudo ip link delete tunl0 2>/dev/null

# 4.7 清 iptables —— 每个表都要单独 -F 和 -X（`iptables -X` 默认只作用于 filter 表！）
for t in filter nat mangle raw; do sudo iptables -t $t -F; sudo iptables -t $t -X; done
for t in filter nat mangle raw; do sudo ip6tables -t $t -F; sudo ip6tables -t $t -X; done

# 4.8 停掉并 disable kubelet
sudo systemctl disable kubelet
sudo systemctl stop kubelet
```

> ⚠️ 4.7 的 `-F` 会清空**本机全部** iptables 规则。这台是纯 worker，没有别的防火墙业务；**如果这台机器上还有 Docker 或其他依赖 iptables 的服务，跳过这条，改用手工只删 `cali-*`/`KUBE-*` 链**。

校验：

```bash
ls -A /etc/kubernetes/         # 只剩空的 manifests / pki 目录
ls -A /etc/cni/net.d/          # 只剩 .kubernetes-cni-keep 占位
ip route | grep 10.244         # 应为空
ip -4 addr show tunl0          # 不应有 inet 行（设备本身可能作为 fallback 存在）
for t in filter nat mangle; do echo "$t: $(sudo iptables -t $t -S | grep -c cali)"; done   # 全 0
systemctl is-active kubelet    # inactive
```

### 阶段 5：平台侧删节点 + Calico IPAM 清理

回到 master（任意一台）执行：

```bash
# 5.1 删节点对象
kubectl delete node k8s-worker-05

# 5.2 查 Calico 残留（大概率 blockaffinity 还在）
kubectl get blockaffinities.crd.projectcalico.org | grep worker-05

# 5.3 若残留，手工删除（删 blockaffinity 后 calico-kube-controllers 会自动回收对应 ipamblock）
kubectl delete blockaffinities.crd.projectcalico.org k8s-worker-05-10-244-55-192-26

# 5.4 再查 ipamblock 是否回收（应看不到 10.244.55.192/26）
kubectl get ipamblocks.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr

# 5.5 实测发现 ipamblock 也不会自动回收。确认 64 个 allocation 全空后手工删
kubectl get ipamblock 10-244-55-192-26 -o jsonpath='{.spec.allocations}'   # 应全为 null
kubectl delete ipamblock 10-244-55-192-26
```

**为什么必须清这一步**：Calico 的 `blockaffinity` 是手工/控制器管理的独立 CRD，`kubectl delete node` 不保证连带删除；`ipamblock` 的 GC 在本环境实测也没触发。残留的块会让 IPPool 误以为那 64 个地址仍被占用，长期累积会耗尽地址池。

> 若 `kubectl delete blockaffinity` 报 "resource is in use" 或有 allocation 未释放，先确认该节点的 Pod 已全部消失（阶段 3 已保证）；确认期间可 `kubectl get ipamblock <块名> -o jsonpath='{.spec.allocations}'` 逐项核对。

### 阶段 6：分叉

#### 场景 A：改名后重新加入（推荐）

```bash
# A.1 在 worker-05 上改主机名
sudo hostnamectl set-hostname k8s-worker-02

# A.2 更新 /etc/hosts 里自身条目（第 105 行那行）
sudo sed -i 's/^192\.168\.1\.105.*/192.168.1.105  k8s-worker-02/' /etc/hosts

# A.3 保留 kubelet / kubeadm / containerd（不要卸载），直接重新 join
#     在 master 上生成 join 命令
kubeadm token create --print-join-command

# A.4 在 worker 上执行 join（约 3 分钟恢复到 Ready）
sudo kubeadm join 192.168.1.100:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>

# A.5 打 worker 标签 + 四台 master/worker-01 补 hosts 新名字
kubectl label node k8s-worker-02 node-role.kubernetes.io/worker='' --overwrite
```

#### 场景 B：彻底退役

```bash
# B.1 卸载 k8s 组件（保留 containerd 可选）
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get purge -y kubeadm kubelet kubectl
sudo apt-get autoremove -y

# B.2 若不再需要容器运行时（释放 1.8G 镜像 + 运行时空间）
sudo apt-get purge -y containerd
sudo rm -rf /var/lib/containerd /etc/containerd

# B.3 移除 join 时加的 sysctl / modules（可选，若机器要做别的用途）
sudo rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/99-k8s.conf

# B.4 若曾关闭 swap 而机器要还原为通用用途，可恢复 /etc/fstab 里的 swap 行
```

---

## 4. 验收清单

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 1 | 节点已消失 | `kubectl get nodes` | 只剩 4 台（3 cp + worker-01） |
| 2 | 该节点无 Pod | `kubectl get pods -A -o wide \| grep worker-05` | 空 |
| 3 | blockaffinity 已清 | `kubectl get blockaffinities \| grep worker-05` | 空 |
| 4 | ipamblock 已回收 | `kubectl get ipamblocks -o wide` | 无 `10.244.55.192/26` |
| 5 | CSINode 已清 | `kubectl get csinode` | 无 worker-05 |
| 6 | lease 已清 | `kubectl -n kube-node-lease get lease` | 无 worker-05 |
| 7 | 集群健康 | `kubectl get nodes` / `kubectl get pods -A` | 全 Ready / 全部 Running |
| 8 | etcd 未受影响 | etcdctl member list + endpoint health | 3/3 started + healthy |
| 9 | 面板可用 | `curl -o /dev/null -w '%{http_code}' http://192.168.1.100:30080/`（:30081 同理） | 200 |
| 10 | 节点本地干净 | worker 上 `ip link show tunl0; ls /etc/cni/net.d/` | 不存在 / 空 |

---

## 5. 回滚方案

| 中断位置 | 回滚动作 |
|---|---|
| 阶段 2 之后（仅 cordon） | `kubectl uncordon k8s-worker-05`，10 秒恢复，无副作用 |
| 阶段 3 之后（已 drain） | `kubectl uncordon` + 重启该节点的 DS（通常自动恢复） |
| 阶段 4 之后（已 reset） | 重新 `kubeadm join`（3 分钟）；此时节点名不变，`kubectl delete node` **尚未执行**，join 回来是同一个 node 对象 |
| 阶段 5 之后（已删节点 + 清 IPAM） | 重新 join 会创建全新 node 对象、分配新 `/26` 块，等同于"新加一台" |

---

## 6. 红线与注意

1. **不要**为了"快"跳过 `cordon` 直接 `kubeadm reset` —— 期间若有 Pod 调度进来会变成孤儿
2. **不要**先 `kubectl delete node` 再 reset —— kubelet 会在删除期间反复重注册、日志刷错
3. **不要**忘记删 `blockaffinity` —— 这是最常见的"删了节点但 IPAM 没清"来源
4. **不要**在 `.105` 上执行 `ip link delete tunl0` 之前就重新 join —— 旧路由会与新分配的块冲突
5. **不要**动 `.101/.102/.103` 的 etcd，本次操作与 etcd 无关
6. 若之后要恢复 master 污点把业务收敛到 worker，注意此时只剩 1 台 worker（`.104`），容量会吃紧，建议先在 A 场景下把 `.105` 以新名字加回来

---

## 7. 后续同步（执行后必做）

| 文件 | 变更 |
|---|---|
| `.workbuddy/reports/run_inspect.py` | `NODES` 列表移除 .105（或改成新主机名） |
| `README.md` | 节点表、ASCII 拓扑改回 4 节点（场景 A 改名为 5 节点） |
| `k8s-topology.svg` | 删除/改名 worker-05 框 |
| `k8s-ops-commands.md` | 附录 C 节点行、变更记录 |
| `k8s-add-worker-node-plan.md` | 第 9 节补「已移除」说明与原因 |

---

## 8. 执行记录（2026-10-31 17:45 → 17:55，已按场景 A 完成）

### 8.1 结果

**`k8s-worker-05` 已移除，同一台机器改名为 `k8s-worker-02` 重新加入，集群回到 5 节点全 Ready。**

| 阶段 | 实测结果 | 耗时 |
|---|---|---|
| 1 预检 | 仅 `calico-node-vb5s5` / `kube-proxy-lcb42` 两个 DS Pod；唯一 PV（kuboard）nodeAffinity 指向 master-01，与 .105 无关 | ~1 min |
| 2 cordon | `node/k8s-worker-05 cordoned`，`unschedulable=true` | 5 s |
| 3 drain | `node/k8s-worker-05 drained`，**0 个 Pod 被驱逐**（DS 按预期忽略），状态转 `Ready,SchedulingDisabled` | 10 s |
| 4 节点 reset | `kubeadm reset -f` 成功；容器清零；`/etc/cni/net.d` 清空（只剩 `.kubernetes-cni-keep` 占位）；kubelet `inactive/disabled` | ~2 min |
| 5 平台侧清理 | `kubectl delete node` 成功；**blockaffinity 未自动回收，手工删除**；ipamblock 也需手工删（见 8.3）；CSINode / lease 自动回收 | ~3 min |
| 6 改名重加 | `hostnamectl` → `k8s-worker-02`；hosts 修正；join 成功，**59 秒转 Ready**（镜像有缓存）；新 block `10.244.118.64/26` | ~4 min |

### 8.2 验收实测（重加后）

| 项 | 结果 |
|---|---|
| 节点 | **5 台 Ready**：3 control-plane + `k8s-worker-01` + `k8s-worker-02`，全部 v1.34.13 / containerd 2.2.1 |
| 网络 | calico-node `nt846` / kube-proxy `j9dsg` 均 1/1 Running；`NetworkUnavailable=False` |
| IPAM | blockaffinity 5 个、ipamblock 5 个，与 5 节点一一对应；旧块 `10.244.55.192/26` 已释放，新分配 `10.244.118.64/26` |
| 跨节点通信 | worker-02 Pod `10.244.118.65` → kuboard-db `10.244.151.136`：**3/3 收包，0% loss，avg 0.334ms** |
| DNS / Service / API | `kubernetes.default.svc.ai4system.com` → 10.96.0.1；kuboard Service 200；VIP:6443 healthz 200 |
| 全集群 Pod | 除 Completed 外全部 Running |
| 面板 | Kuboard `:30080` 200、Headlamp `:30081` 200 |
| hosts | 3 台 master + worker-01 均已把 `.105` 条目更新为 `k8s-worker-02` |

### 8.3 实操中发现的 3 个「计划里没写透」的坑（已回归文档）

1. **`iptables -X` 默认只作用于 filter 表**
   命令 `iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X` 中，最后的 `-X` 只删 filter 表的自定义链，**nat 表残留 6 条 `cali-*` 链**（`cali-OUTPUT`、`cali-POSTROUTING`、`cali-fip-dnat` 等）。
   **正确写法：每个表单独 `-F` + `-X`**
   ```bash
   for t in filter nat mangle raw; do iptables -t $t -F; iptables -t $t -X; done
   for t in filter nat mangle raw; do ip6tables -t $t -F; ip6tables -t $t -X; done
   ```

2. **`tunl0` 删了会立刻重建，且带着 Calico 的 `/32` 地址**
   `tunl0` 是 ipip 模块的 fallback 设备，`ip link delete tunl0` 返回成功但设备会立即重建，`inet 10.244.55.192/32` 仍在。
   根本原因是**路由表里还有 5 条 Calico 路由**（4 条 `via ... dev tunl0` + 1 条 `blackhole 10.244.55.192/26`，`proto 80`）在引用它。
   **正确顺序：先清路由，再删地址，最后删设备**
   ```bash
   ip route flush proto 80              # 一次清掉所有 Calico 路由
   ip addr del 10.244.55.192/32 dev tunl0
   ip link set tunl0 down; ip link delete tunl0
   ```
   即便如此 `tunl0` 可能仍作为 fallback 设备存在——**只要它没有 IPv4 地址、没有 10.244 路由，就是干净的**，重新 join 后 Calico 会重新配置它。

3. **`kubectl delete node` 之后 `blockaffinity` 和 `ipamblock` 都不会自动回收**
   - `blockaffinity` 保留了下来，需手工 `kubectl delete blockaffinities.crd.projectcalico.org k8s-worker-05-10-244-55-192-26`
   - 删完 blockaffinity 后等 40 秒，`ipamblock 10-244-55-192-26` **仍在**（controller GC 没触发）。核实其 64 个 `allocations` 全为 null 后直接删：
     ```bash
     kubectl get ipamblock 10-244-55-192-26 -o jsonpath='{.spec.allocations}'   # 确认全 null
     kubectl delete ipamblock 10-244-55-192-26
     ```
   删完后 5 节点对应 5 个 blockaffinity / 5 个 ipamblock，无悬空块。

### 8.4 改名后需要同步的地方（容易漏）

| 位置 | 动作 |
|---|---|
| 本机 `/etc/hosts` | 改 `127.0.1.1` 行 + `192.168.1.105` 行（`hostnamectl` **不会**动 hosts） |
| 其余 4 台 `/etc/hosts` | `sed -i 's/^192\.168\.1\.105.*/192.168.1.105  k8s-worker-02/'` |
| 巡检脚本 | `run_inspect.py` 的 `NODES` 列表 |
| 拓扑与文档 | README、`k8s-topology.svg`、运维手册附录 C |

### 8.5 耗时对比

- 纯移除（场景 B 走到删节点）：约 **4 分钟**
- 移除 + 改名重加（场景 A）：约 **10 分钟**（其中 join 到 Ready 仅 59 秒，因为 containerd 镜像还在）

> 镜像缓存是场景 A 的最大收益：不 purge containerd，重加时 calico/node 等 1.8G 镜像无需重新拉取。
