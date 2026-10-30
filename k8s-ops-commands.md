# Kubernetes 运维命令手册（v1.34 实测环境）

> 适用范围：本工作区已部署的 3 节点 HA 控制平面集群
> 集群参数：VIP `192.168.1.100:6443` / 网卡 `ens160` / DNS 域 `ai4system.com` / Pod `10.244.0.0/16` / Service `10.96.0.0/12` / Calico v3.33 IPIP / containerd 2.2.1
> 配套文档：`k8s-ha-install-manual.md`（安装）、`k8s-inspection-report-2026-10-30.md`（巡检）

---

## 目录

| 章 | 内容 | 典型场景 |
|---|---|---|
| [0](#0-30-秒上手最常用的-12-条) | 30 秒上手 | 只想快速看一眼 |
| [1](#1-集群与节点) | 集群与节点 | 节点 NotReady、维护、容量 |
| [2](#2-工作负载) | 工作负载 | 查 Pod、日志、重启、回滚 |
| [3](#3-排错主线五步定位法) | **排错主线（五步法）** | **Pod 起不来 / 一直重启** |
| [4](#4-网络) | 网络 | DNS 不通、跨节点不通、Service 无响应 |
| [5](#5-存储) | 存储 | PVC Pending、挂载失败 |
| [6](#6-配置与密钥) | ConfigMap / Secret | 改配置后不生效 |
| [7](#7-权限与证书) | 权限与证书 | 403、证书到期 |
| [8](#8-控制面与-etcd) | 控制面与 etcd | etcd 健康、快照、恢复 |
| [9](#9-containerd-与镜像) | containerd 与镜像 | ImagePullBackOff、磁盘满 |
| [10](#10-资源与容量) | 资源与容量 | 容量规划、OOM |
| [11](#11-备份与升级) | 备份与升级 | 版本升级、灾备 |
| [12](#12-高频-jsonpath-与自定义列模板) | JSONPath 模板库 | 批量提取信息 |
| [13](#13-高危命令红黑榜) | **高危命令红黑榜** | **执行前必看** |
| [附录-a](#附录-a-别名与-shell-增强) | 别名与增强 | 少打字 |
| [附录-b](#附录-b-按症状查命令) | 按症状查命令 | 出问题反查 |
| [附录-c](#附录-c-本集群固定参数) | 本集群固定参数 | 复制粘贴用 |

**约定**
- `k` = `kubectl`（如果配了别名，见附录 A）
- 标注 `[本环境]` 的命令含本集群专属参数（节点名、VIP、网卡名）
- 需要 root 的命令统一用 `sudo`，密码不在文档中，通过 `export SUDO_PW=...` 传入脚本
- 命名空间 `-n kube-system` 常简写为 `-n ks`（需自行配别名）

---

## 0. 30 秒上手：最常用的 12 条

```bash
# 1 集群健康一眼看
kubectl get nodes -o wide && kubectl -n kube-system get pods -o wide

# 2 API 是否活着
kubectl get --raw /healthz; echo

# 3 所有非 Running 的 Pod（最实用的一条）
#   注意：Completed 的 Job Pod 也会列出来，属正常
kubectl get pods -A --field-selector=status.phase!=Running

# 4 重启次数最多的 Pod Top10
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount | tail -10

# 5 最近发生了什么（按时间排序）
#   注意：Event 默认只保留 1 小时（EventTTL），空闲集群查出来可能是空的
#   本集群实测此刻就是 0 条——排错必须在故障窗口内取，事后查不到
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -20

# 6 看某个 Pod 的日志
kubectl logs -f --tail=100 <pod>

# 7 进容器
kubectl exec -it <pod> -- /bin/sh

# 8 某个资源详情（排错第一步）
kubectl describe pod <pod>

# 9 节点上容器运行时状态
sudo crictl ps -a | head -20

# 10 VIP 当前在哪台
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'

# 11 etcd 健康
sudo kubeadm certs check-expiration | head -8

# 12 一键巡检（本工作区脚本）
cd /Users/chloe/WorkBuddy/K8S && SUDO_PW=*** ./scripts/k8s_inspect_cluster.sh 192.168.1.101
```

---

## 1. 集群与节点

### 1.1 集群信息

```bash
# 版本（客户端 + 服务端）
kubectl version -o yaml

# 集群信息汇总（API 地址、DNS 域、CNI 插件名）
kubectl cluster-info
kubectl cluster-info dump | head -50      # 完整快照，输出很大

# 组件状态（kubeadm 集群）
kubectl get componentstatuses 2>/dev/null || echo "1.19+ 已弃用，改用下面的方式"

# 控制面静态 Pod 列表
kubectl -n kube-system get pods -l tier=control-plane -o wide

# 各组件健康端点
kubectl get --raw /healthz
kubectl get --raw /livez
kubectl get --raw /readyz
kubectl get --raw "/readyz?verbose"        # 逐项检查，失败时定位到具体 informer（? 必须加引号）
kubectl get --raw /metrics | head          # apiserver 指标
```

### 1.2 节点状态

```bash
# 概览
kubectl get nodes -o wide

# 节点详细状态（Conditions / 容量 / 已分配 / 污点）
kubectl describe node k8s-master-01        # [本环境]

# 只看 Conditions（Ready / MemoryPressure / DiskPressure / PIDPressure / NetworkUnavailable）
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.conditions[*]}  {.type}={.status} ({.reason}){"\n"}{end}{end}'

# 节点资源（allocatable vs 已分配）
kubectl describe node k8s-master-01 | grep -A8 "Allocated resources"

# 单节点上的 Pod（含静态 Pod）
kubectl get pods -A --field-selector spec.nodeName=k8s-master-01 -o wide

# 节点上占用资源最多的 Pod
kubectl describe node k8s-master-01 | sed -n '/Non-terminated Pods/,/Allocated resources/p'

# 节点 IP / 主机名 / 系统 / 内核
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address,\
HOSTNAME:.status.addresses[?\(@.type==\"Hostname\"\)].address,\
OS:.status.nodeInfo.osImage,\
KERNEL:.status.nodeInfo.kernelVersion,\
RUNTIME:.status.nodeInfo.containerRuntimeVersion

# 节点心跳时间（判断是否失联）
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}{"\n"}{end}'
```

### 1.3 标签与污点

```bash
# 打标签
kubectl label node k8s-master-02 topology.kubernetes.io/zone=vmware-a
kubectl label node k8s-master-02 disktype=ssd --overwrite
kubectl label node k8s-master-02 gpu-          # 末尾加 - 表示删除

# 按标签选节点
kubectl get nodes -l topology.kubernetes.io/zone=vmware-a

# 查看污点
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# 打污点 / 去污点
kubectl taint node k8s-master-02 maintenance=true:NoSchedule
kubectl taint node k8s-master-02 maintenance-                # 删除该 key 的污点
kubectl taint nodes --all node-role.kubernetes.io/control-plane-   # [本环境] 已执行过，业务 Pod 才能调度

# 污点效果说明
#   NoSchedule       新 Pod 不调度（已有 Pod 不动）
#   PreferNoSchedule 尽量不调度
#   NoExecute        不调度 + 驱逐已有 Pod（可配 tolerationSeconds）
```

### 1.4 节点维护（cordon / drain / uncordon）

```bash
# 1 标记不可调度（新 Pod 不再进来，已有 Pod 不受影响）
kubectl cordon k8s-master-02

# 2 驱逐（会重建 Pod 到其他节点）
kubectl drain k8s-master-02 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --timeout=300s

# 3 维护完恢复
kubectl uncordon k8s-master-02

# 4 确认恢复
kubectl get nodes
```

> **[本环境] 特别注意**：三台都是控制平面，`drain` 一台的影响是
> - etcd 从 3 票变 2 票，**仍可用**（容错 1 台），但同时再挂一台就会**失去 quorum 只读不可写**
> - 若 VIP 当前在该节点，kube-vip 会在 5 秒内漂移，客户端感知为秒级闪断
> - 先 `kubectl -n kube-system get lease plndr-cp-lock` 确认 VIP 不在目标节点，可避免闪断

### 1.5 节点级排错

```bash
# 节点 NotReady 三板斧
ssh lumz@192.168.1.102                                  # [本环境]
sudo systemctl status kubelet --no-pager -l | tail -20
sudo journalctl -u kubelet --since "10 min ago" --no-pager | grep -iE "error|fail" | tail -20
sudo systemctl status containerd
sudo crictl ps 2>&1 | head -5                          # 运行时是否响应

# 常见原因与判定
#   DiskPressure   → df -h /；crictl rmi --prune；删 /var/log 大文件
#   MemoryPressure → free -h；dmesg -T | grep -i oom
#   PIDPressure    → ps -eLf | wc -l
#   证书过期       → sudo kubeadm certs check-expiration
#   时间不同步     → timedatectl；chronyc tracking

# 节点磁盘/inode
df -h / /var/lib/containerd /var/lib/kubelet
df -i /

# 节点 OOM 记录
sudo dmesg -T | grep -iE "out of memory|oom-kill" | tail -10
sudo journalctl -k --since "1 day ago" | grep -i oom | tail

# 节点上 IO 错误（磁盘故障前兆）
sudo dmesg -T | grep -iE "I/O error|medium error|ata.*failed" | tail
```

---

## 2. 工作负载

### 2.1 查询

```bash
# 常用列表
kubectl get pods -A -o wide
kubectl get deploy,sts,ds -A
kubectl get all -n <ns>                 # 不含 CRD 资源

# 按标签
kubectl get pods -l app=nginx -o wide
kubectl get pods -l 'app in (web,api),env!=dev'

# 按字段（服务端过滤，比 grep 快）
kubectl get pods -A --field-selector status.phase=Failed
kubectl get pods -A --field-selector spec.nodeName=k8s-master-03
kubectl get pods --field-selector metadata.namespace!=kube-system

# 排序
kubectl get pods -A --sort-by=.status.startTime
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount'

# 看已完成的 Job Pod（默认隐藏）
kubectl get pods -A --show-labels | grep -v Completed
kubectl get pods --field-selector status.phase=Succeeded

# 实时观察
kubectl get pods -A -w
kubectl get events -A -w --sort-by=.metadata.creationTimestamp

# 等条件成立（脚本里比 sleep 靠谱）
kubectl wait --for=condition=Ready pod/web-xxx --timeout=120s
kubectl wait --for=condition=Available deploy/web --timeout=180s
```

### 2.2 日志

```bash
# 基础
kubectl logs <pod>
kubectl logs -f --tail=200 <pod>                       # 跟随 + 最后 200 行
kubectl logs --since=30m <pod>                         # 时间窗
kubectl logs --since-time="2026-10-30T10:00:00Z" <pod>

# 崩溃后排错（重启前的日志，最重要）
kubectl logs <pod> --previous
kubectl logs <pod> -p --tail=100

# 多容器 Pod 必须指定容器
kubectl logs <pod> -c <container>
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}'; echo   # 先列出容器名

# 按标签批量取（Deployment 下所有副本合并）
kubectl logs -l app=web --tail=50 --max-log-requests=20
kubectl logs -l app=web --all-containers --prefix

# 时间戳 + 精确定位
kubectl logs <pod> --timestamps | grep -i error | tail -20

# 上一轮容器退出码（判断 137=OOM/SIGKILL，1=应用错误，143=SIGTERM）
kubectl get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{" exit="}{.lastState.terminated.exitCode}{" reason="}{.lastState.terminated.reason}{"\n"}{end}'

# 静态 Pod 日志（走 kubelet，kubectl logs 也能用）
kubectl -n kube-system logs kube-apiserver-k8s-master-01 --tail=50      # [本环境]
kubectl -n kube-system logs etcd-k8s-master-01 --tail=50

# 节点上直接看（kubectl 不通时）
sudo journalctl -u kubelet -f
sudo crictl logs <container-id>
sudo crictl ps -a --name kube-apiserver
```

> 多 Pod 日志聚合推荐 `stern`（见附录 A），一条命令看整个 Deployment 的日志流。

### 2.3 进入容器与文件传输

```bash
# 交互 shell（优先 sh，distroless 镜像没有 bash）
kubectl exec -it <pod> -- /bin/sh
kubectl exec -it <pod> -c <container> -- bash

# 单条命令
kubectl exec <pod> -- cat /etc/resolv.conf
kubectl exec <pod> -- env | sort
kubectl exec <pod> -- sh -c 'ps aux; df -h'

# distroless / scratch 镜像没有 shell → 用临时容器（Pod 内新增一个调试容器，共享网络和进程）
kubectl debug -it <pod> --image=busybox:1.36 --target=<container>
#  --target 让临时容器共享目标容器的进程命名空间，可看到对方的进程

# 复制 Pod 副本并改造（不碰线上 Pod）
kubectl debug <pod> --image=busybox:1.36 --copy-to=debug-pod --share-processes -- sleep 3600

# 调试节点本身（在节点上起特权 Pod，挂宿主机根目录到 /host）
kubectl debug node/k8s-master-02 -it --image=busybox:1.36

# 文件互拷
kubectl cp <pod>:/etc/nginx/nginx.conf ./nginx.conf
kubectl cp ./app.jar <ns>/<pod>:/tmp/app.jar -c <container>

# 端口转发（不暴露 Service 也能本地访问）
kubectl port-forward <pod> 8080:80
kubectl port-forward svc/web 8080:80
kubectl port-forward -n kube-system svc/kube-dns 5353:53
```

### 2.4 Deployment / StatefulSet / DaemonSet

```bash
# 扩缩容
kubectl scale deploy web --replicas=5
kubectl scale sts mysql --replicas=3
kubectl autoscale deploy web --min=2 --max=10 --cpu-percent=70   # 需 metrics-server

# 滚动重启（改配置后最常用）
kubectl rollout restart deploy/web
kubectl rollout restart ds/calico-node -n kube-system

# 观察进度
kubectl rollout status deploy/web --timeout=180s

# 历史与回滚
kubectl rollout history deploy/web
kubectl rollout history deploy/web --revision=3
kubectl rollout undo deploy/web
kubectl rollout undo deploy/web --to-revision=2

# 暂停/恢复滚动（批量改配置时避免多次触发）
kubectl rollout pause deploy/web
kubectl rollout resume deploy/web

# 查看某次变更的内容
kubectl annotate deploy/web kubernetes.io/change-cause="升级镜像到 v2.1" --overwrite
kubectl rollout history deploy/web --revision=4

# 镜像更新（三种写法等价，推荐第一种可回滚）
kubectl set image deploy/web web=nginx:1.27
kubectl patch deploy/web -p '{"spec":{"template":{"spec":{"containers":[{"name":"web","image":"nginx:1.27"}]}}}}'
kubectl edit deploy/web

# StatefulSet 特殊点：按序创建/删除，扩容前一个 Ready 才起下一个
kubectl get sts mysql -o jsonpath='{.status.currentReplicas}/{.status.replicas}{"\n"}'

# DaemonSet 检查每节点是否都有实例
kubectl get ds -n kube-system
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide

# 查看 Deployment 与 ReplicaSet 关系（排查"旧 Pod 不消失"）
kubectl get rs -l app=web
kubectl describe rs web-7d9f8b6c5

# 查看滚动策略与就绪配置
kubectl get deploy web -o jsonpath='{.spec.strategy}{"\n"}{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
```

### 2.5 Job / CronJob

```bash
kubectl get jobs -A
kubectl get cronjobs -A
kubectl logs job/db-migrate

# 手动触发一次 CronJob（1.27+）
kubectl create job --from=cronjob/etcd-backup manual-backup-$(date +%H%M)

# 暂停 CronJob（改错配置时先停）
kubectl patch cronjob etcd-backup -p '{"spec":{"suspend":true}}'

# 查看最近调度时间与是否失败
kubectl get cronjob etcd-backup -o jsonpath='{.status.lastScheduleTime}{" / "}{.status.lastSuccessfulTime}{"\n"}'
```

---

## 3. 排错主线（五步定位法）

**任何"Pod 不对"的问题，按顺序走这五步，能定位 90% 的问题。**

```bash
P=<pod-name>; NS=<namespace>

# ① 状态：是什么现象
kubectl -n $NS get pod $P -o wide
kubectl -n $NS get pod $P -o jsonpath='{.status.phase} / {.status.qosClass}{"\n"}'

# ② 详情：Events 里通常直接写着答案
kubectl -n $NS describe pod $P | tail -30

# ③ 事件：describe 被截断时按对象精确取
kubectl -n $NS get events --field-selector involvedObject.name=$P --sort-by=.lastTimestamp

# ④ 日志：容器是否真的跑起来了
kubectl -n $NS logs $P --tail=100
kubectl -n $NS logs $P --previous --tail=100      # 崩过的话看上一轮

# ⑤ 进容器：网络/配置/文件是否如预期
kubectl -n $NS exec -it $P -- sh
```

### 3.1 Pod 状态字典（看到 X 该查什么）

| 状态 | 含义 | 首查命令 | 常见根因 |
|---|---|---|---|
| `Pending` | 未调度到节点 | `describe` 看 Events | 资源不足、污点、亲和性、PVC 未绑定、节点全 cordon |
| `ContainerCreating` | 调度了但容器没起来 | `describe` + 节点 `crictl ps -a` | 拉镜像慢、CNI 未就绪、挂载失败、Secret/ConfigMap 缺失 |
| `ImagePullBackOff` / `ErrImagePull` | 拉不到镜像 | `describe` 看 image 与 Events | 镜像名错、私有仓库无 secret、镜像源不通 |
| `CrashLoopBackOff` | 起来又崩，反复重启 | `logs --previous` | 应用启动报错、依赖未就绪、探针太严、命令写错 |
| `Running 0/1` | 容器跑着但 ready 为 false | `describe` 看 Readiness 探针 | 探针路径/端口错、应用启动慢于 initialDelay |
| `Running` 但重启多 | 间歇性崩溃 | `logs --previous` + 退出码 | OOMKilled(137)、被 liveness 杀、节点压力 |
| `OOMKilled` | 超 limits 被杀 | `describe` 看 limits 与 Last State | limits 太小、内存泄漏 |
| `Evicted` | 被 kubelet 驱逐 | `describe` 看 Reason/Message | 节点 DiskPressure / MemoryPressure |
| `Terminating` 卡住 | 删不掉 | 见 3.3 | finalizer、kubelet 失联、volume 卸载卡住 |
| `Completed` | Job 正常结束 | — | 正常 |
| `Error` | 非 0 退出 | `logs` | 应用返回错误 |
| `Unknown` | 节点失联 | `kubectl get nodes` | kubelet 挂了 / 网络断 |
| `Init:0/1` | init 容器没完成 | `logs $P -c <init-container>` | init 容器逻辑失败 |

### 3.2 各状态的标准处理

```bash
# Pending：先看调度器怎么说
kubectl -n $NS describe pod $P | grep -A10 Events
kubectl -n $NS get pod $P -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}{"\n"}'
kubectl -n kube-system logs -l component=kube-scheduler --tail=30      # 调度器视角

# Pending 且 PVC 未绑定
kubectl -n $NS get pvc
kubectl -n $NS describe pvc <pvc>

# ImagePullBackOff：先确认镜像名，再在节点上裸拉
kubectl -n $NS get pod $P -o jsonpath='{range .spec.containers[*]}{.image}{"\n"}{end}'
sudo crictl pull <image>                                 # 在 Pod 所在节点执行
sudo crictl pull --creds user:pass <私有仓库镜像>

# CrashLoopBackOff：看退出码与上一轮日志
kubectl -n $NS logs $P --previous --tail=50
kubectl -n $NS get pod $P -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}'
# 137 = SIGKILL（多半 OOM 或被 liveness 杀）
# 143 = SIGTERM（优雅退出，常是 liveness 触发）
# 1   = 应用自身错误

# 临时把它从崩溃循环里拉出来调试（覆盖 command 为 sleep，别改线上）
kubectl -n $NS debug $P --copy-to=${P}-debug --image=busybox:1.36 -- sleep 3600

# Ready 0/1：看探针配置是否合理
kubectl -n $NS get pod $P -o jsonpath='{.spec.containers[0].readinessProbe}{"\n"}'
kubectl -n $NS describe pod $P | grep -i "readiness probe failed" | tail -5
```

### 3.3 Pod 卡在 Terminating

```bash
# ① 看是否有 finalizer
kubectl -n $NS get pod $P -o jsonpath='{.metadata.finalizers}{"\n"}'

# ② 手动去掉 finalizer（确认无依赖后）
kubectl -n $NS patch pod $P -p '{"metadata":{"finalizers":null}}' --type=merge

# ③ 强制删除（kubelet 已失联时）
kubectl -n $NS delete pod $P --force --grace-period=0

# ④ 若因 volume 无法卸载，检查节点上的挂载残留
sudo grep <pvc-id> /proc/mounts
sudo umount /var/lib/kubelet/pods/<uid>/volumes/...

# ⑤ 节点失联导致的 Unknown Pod，直接清理（确认节点真的不回来了）
kubectl -n $NS delete pod $P --force --grace-period=0
```

### 3.4 "服务能跑但访问不到"的排查顺序

```bash
# 从内往外一层层剥
kubectl -n $NS get pod -l app=web -o wide          # ① Pod 是否 Ready、IP 是多少
kubectl -n $NS get svc web -o wide                 # ② selector 与 port 是否正确
kubectl -n $NS get endpoints web                   # ③ 有没有 Endpoint（空 = selector 不匹配或 Pod 未 Ready）
kubectl -n $NS get endpointslices -l kubernetes.io/service-name=web

# Pod 内自测（区分"应用问题"还是"网络问题"）
kubectl -n $NS exec -it <client-pod> -- wget -qO- --timeout=3 http://web:80
kubectl -n $NS exec -it <client-pod> -- wget -qO- --timeout=3 http://<pod-ip>:80   # 绕过 Service 直连 Pod

# 结论映射
#   Pod IP 通、Service 不通  → kube-proxy / iptables 规则问题
#   Pod IP 也不通            → CNI 问题（见第 4 章）
#   Endpoint 为空            → selector / readiness 问题
#   本机通、跨节点不通        → 隧道 / 安全组 / 防火墙
```

---

## 4. 网络

### 4.1 Service 与 Endpoint

```bash
kubectl get svc -A
kubectl get svc web -o yaml
kubectl get endpoints -A                       # 空 Endpoints 是最常见的"服务不通"原因
kubectl get endpointslices -A

# 找出所有空 Endpoint 的 Service（巡检常用）
kubectl get endpoints -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{.subsets[*].addresses[*].ip}{"\n"}{end}' | awk 'NF==1'

# Service 后端 Pod
kubectl get pod -l $(kubectl get svc web -o jsonpath='{.spec.selector}' | tr -d '{}"' | tr ',' '=' | sed 's/:/=/g') -o wide

# 端口映射关系
kubectl get svc web -o jsonpath='{.spec.ports}{"\n"}'
```

### 4.2 DNS（本集群必查项）

```bash
# 集群 DNS 服务
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=30

# CoreDNS 配置（含 dnsDomain，本集群为 ai4system.com）
kubectl -n kube-system get cm coredns -o yaml
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'

# 在 Pod 内验证（busybox 自带 nslookup，镜像已有）
kubectl run dnstest --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.ai4system.com            # [本环境]

# 短名解析（验证 search 域）
kubectl run dnstest --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc

# 集群内 Pod 的 resolv.conf
kubectl exec -it <pod> -- cat /etc/resolv.conf
# 正常应为：
#   nameserver 10.96.0.10
#   search <ns>.svc.ai4system.com svc.ai4system.com ai4system.com
#   options ndots:5

# 外部域名解析（验证上游 DNS）
kubectl run dnstest --image=busybox:1.36 --rm -it --restart=Never -- nslookup www.baidu.com

# 完整诊断（需要 dnsutils 镜像，含 dig）
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 \
  --rm -it --restart=Never -- dig +search +noall +answer web
```

**DNS 故障判定表**

| 现象 | 根因 | 处理 |
|---|---|---|
| 短名解析失败、全名成功 | search 域不对 | 检查 Pod 的 `dnsPolicy` 与集群 `dnsDomain` |
| 全名也失败，但 `10.96.0.10` ping 通 | CoreDNS 无后端 / 配置错 | `kubectl logs -n kube-system -l k8s-app=kube-dns` |
| `10.96.0.10` 不通 | kube-proxy 规则或 CNI 问题 | 看 4.4 kube-proxy |
| 解析到旧 IP | NodeLocalDNS 缓存 / 客户端缓存 | 重启客户端 Pod |
| 间歇性 5s 超时 | conntrack 表满 / UDP 丢包 | 见 4.6 |

### 4.3 跨节点 Pod 网络（Calico IPIP）

```bash
# 本集群封装模式确认（IPIP，不是 VXLAN）
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool \
  -o jsonpath='ipipMode={.spec.ipipMode} vxlanMode={.spec.vxlanMode}{"\n"}'
# 期望：ipipMode=Always vxlanMode=Never

# Calico 组件状态
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
kubectl -n kube-system logs -l k8s-app=calico-node --tail=30
kubectl -n kube-system logs <calico-node-pod> -c install-cni --tail=20

# 节点上隧道接口（IPIP 的 tunl0）
ip -br addr show tunl0
ip link show tunl0

# BGP 邻居与路由（在 calico-node 容器内）
#   注意：Calico 3.33 的二进制是 calico，不是 calico-node；health 检查成功时无输出
CPOD=$(kubectl -n kube-system get pod -l k8s-app=calico-node \
  --field-selector spec.nodeName=k8s-master-01 -o name)          # [本环境]
kubectl -n kube-system exec $CPOD -- calico component node health --felix-ready
kubectl -n kube-system exec $CPOD -- calico component node health --bird-ready
#   期望：bird-ready 输出 Number of node(s) with BGP peering established = 2

kubectl -n kube-system exec $CPOD -- birdcl show protocols
#   期望看到 Mesh_192_168_1_102 / Mesh_192_168_1_103 均为 Established
kubectl -n kube-system exec $CPOD -- birdcl show route count
#   实测输出示例：15 of 15 routes for 10 networks

# 说明：calico-node Pod 的 readinessProbe 就是
#   calico component node health --felix-ready --bird-ready
# 所以 Pod 显示 1/1 Ready，等于 felix 与 bird 都已就绪——通常不需要再手工 exec

# IPAM：地址池使用情况（排查"Pod 拿不到 IP"）
kubectl get ippools.crd.projectcalico.org -o yaml | grep -E "cidr|blockSize"
kubectl get ipamblocks.crd.projectcalico.org -o custom-columns=\
CIDR:.spec.cidr,AFFINITY:.spec.affinity
#   要看每个 block 已用几个 IP（allocations 是长数组，直接打印会刷屏）：
kubectl get ipamblocks.crd.projectcalico.org -o json \
  | python3 -c 'import json,sys;[print(b["spec"]["cidr"], b["spec"].get("affinity",""), "used=%d"%len([x for x in b["spec"].get("allocations") or [] if x is not None])) for b in json.load(sys.stdin)["items"]]'
kubectl get ipamhandles.crd.projectcalico.org | wc -l

# 跨节点连通性实测（最直接）
kubectl create deploy web --image=nginx:1.27 --replicas=2
kubectl run client --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in $(seq 1 3); do wget -qO- --timeout=2 http://web && echo OK; done'
kubectl delete deploy web
```

### 4.4 kube-proxy 与 iptables

```bash
# kube-proxy 状态
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=30
kubectl -n kube-system get cm kube-proxy -o yaml | grep -E "mode|clusterCIDR"

# Service 规则是否生成（ClusterIP 为例）
sudo iptables -t nat -L KUBE-SERVICES -n | grep <clusterIP>
sudo iptables -t nat -L KUBE-SVC-XXXX -n          # 后端分发规则
sudo iptables -t nat -L KUBE-SEP-XXXX -n          # 具体 Pod 的 DNAT

# 规则计数（判断有没有流量命中）
sudo iptables -t nat -L KUBE-SERVICES -n -v | head -20

# conntrack（连接跟踪表，满会导致新连接随机失败）
sudo conntrack -C                                  # 当前条目数
cat /proc/sys/net/netfilter/nf_conntrack_max       # 上限
sudo conntrack -S | head                            # 统计与错误
sudo conntrack -L -p tcp --dport 6443 2>/dev/null | head   # 查具体连接

# 丢包与错误
ip -s link show ens160                             # [本环境] 看 RX/TX errors、dropped
netstat -s | grep -iE "retrans|drop|overflow" | head
ss -s
```

### 4.5 NetworkPolicy

```bash
# 查看（本集群当前为 0，是一处 P1 风险）
kubectl get networkpolicy -A
kubectl describe networkpolicy -n demo default-deny

# default-deny 模板（入站全拒）
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: demo
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF

# 放行同命名空间 + 特定标签
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-ns
  namespace: demo
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
EOF

# 验证策略是否生效（策略生效后 curl 应该超时而非拒绝）
kubectl run t --image=busybox:1.36 --rm -it --restart=Never -- \
  wget -qO- --timeout=3 http://web.demo
```

### 4.6 Ingress

```bash
kubectl get ingress -A
kubectl describe ingress -n demo web
kubectl get pods -n ingress-nginx                     # 控制器是否存在
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=50
```

### 4.7 抓包（网络问题的终极手段）

```bash
# 节点上抓（能看到封装后的流量）
sudo tcpdump -i ens160 -nn port 80 -c 20
sudo tcpdump -i tunl0 -nn -c 20                       # IPIP 隧道内层流量

# 抓 Pod 网段到某 Pod 的包
sudo tcpdump -i any -nn host 10.244.1.15 -c 20

# 抓 VIP / apiserver 流量
sudo tcpdump -i ens160 -nn port 6443 -c 20

# 写文件后本地分析
sudo tcpdump -i any -nn -w /tmp/cap.pcap -c 200
# 拷回本地用 Wireshark 打开
```

---

## 5. 存储

```bash
# 全景
kubectl get pv
kubectl get pvc -A
kubectl get sc
kubectl get sc -o yaml | grep -E "provisioner|reclaimPolicy|volumeBindingMode"

# PVC Pending 排查（本集群无 StorageClass，这是必然结果）
kubectl describe pvc <pvc> | tail -20
kubectl get pvc <pvc> -o jsonpath='{.status.conditions[?(@.type=="Pending")].message}{"\n"}'
kubectl get events -A --field-selector involvedObject.name=<pvc>

# 无 SC 时用 hostPath 或 local PV 应急（仅测试环境）
# 生产应装 CSI：local-path / Longhorn / Ceph RBD / NFS-Subdir

# PV 与 PVC 绑定关系
kubectl get pv -o custom-columns=\
NAME:.metadata.name,CAP:.spec.capacity.storage,CLAIM:.spec.claimRef.name,\
NS:.spec.claimRef.namespace,STATUS:.status.phase

# Pod 挂载是否成功
kubectl describe pod <pod> | sed -n '/Volumes:/,/QoS/p'
kubectl exec <pod> -- df -h
kubectl exec <pod> -- mount | grep -E "nfs|rbd|ceph|hostpath"

# 节点上的挂载残留（Pod 卡 Terminating 的常见原因）
sudo ls /var/lib/kubelet/pods/<pod-uid>/volumes/
sudo grep -c "/var/lib/kubelet/pods" /proc/mounts

# StatefulSet 的 PVC 不会随 Pod 删除而释放
kubectl get pvc -l app=mysql
```

---

## 6. 配置与密钥

```bash
# 查看
kubectl get cm -A
kubectl get cm app-config -n demo -o yaml
kubectl get secret db-secret -n demo -o jsonpath='{.data.password}' | base64 -d; echo

# 从文件/字面量创建
kubectl create cm app-config --from-file=config.yaml --dry-run=client -o yaml > cm.yaml
kubectl create secret generic db-secret --from-literal=password='xxx' -n demo

# 更新（apply 比 create 好，可重复执行）
kubectl create cm app-config --from-file=config.yaml -o yaml --dry-run=client | kubectl apply -f -

# 改完为什么不生效：ConfigMap 挂载方式决定是否需要重启
#   subPath 挂载     → 永不热更新，必须重建 Pod
#   非 subPath 挂载  → 约 1 分钟内 kubelet 同步，但应用未必重读文件
kubectl rollout restart deploy/web

# 确认 Pod 里看到的是新值
kubectl exec <pod> -- cat /etc/config/config.yaml

# 校验 Secret 是否真的被挂载
kubectl describe pod <pod> | sed -n '/Mounts:/,/Conditions/p'
```

---

## 7. 权限与证书

### 7.1 权限排查（403 / Forbidden）

```bash
# 我是谁
kubectl auth whoami
kubectl config current-context
kubectl config view --minify

# 我能做什么
kubectl auth can-i --list
kubectl auth can-i create pods -n demo
kubectl auth can-i '*' '*' --all-namespaces

# 模拟某个 ServiceAccount（排查应用 403，最有用）
kubectl auth can-i list pods --as=system:serviceaccount:demo:app-sa -n demo
kubectl auth can-i --list --as=system:serviceaccount:demo:app-sa -n demo

# 模拟普通用户
kubectl auth can-i get secrets --as=lumz --as-group=system:authenticated

# 某个 SA 绑定了哪些角色
kubectl get rolebinding,clusterrolebinding -A -o wide | grep <sa-name>
kubectl describe clusterrolebinding <name>

# 某个角色包含哪些权限
kubectl describe clusterrole cluster-admin
kubectl get clusterrole view -o yaml

# SA 的 token（1.24+ 不再自动生成 Secret，临时取用）
kubectl create token app-sa -n demo --duration=1h
```

### 7.2 证书

```bash
# 全部证书有效期
sudo kubeadm certs check-expiration

# 单个证书详情
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -dates -ext subjectAltName

# kubeconfig 里用的证书
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -dates

# apiserver 服务端证书包含的域名/IP（应含 VIP 与 api.ai4system.com）
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 "Subject Alternative Name"

# 续期（到期前执行，逐台）
sudo kubeadm certs renew all
sudo systemctl restart kubelet          # 让静态 Pod 重新加载新证书

# 检查是否续期成功
sudo kubeadm certs check-expiration

# kubelet 客户端证书（自动轮换，看是否在轮换）
sudo ls -l /var/lib/kubelet/pki/
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates

# CA 证书（10 年，最不能丢）
sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -dates
```

### 7.3 kubeconfig 管理

```bash
# 合并多个 kubeconfig
KUBECONFIG=~/.kube/config:./new.conf kubectl config view --flatten > ~/.kube/merged.conf

# 切换 context
kubectl config get-contexts
kubectl config use-context kubernetes-admin@kubernetes

# 设置默认命名空间
kubectl config set-context --current --namespace=demo

# 用 VIP 访问（推荐，HA 生效）
kubectl config set-cluster kubernetes --server=https://192.168.1.100:6443   # [本环境]

# 导出只读用户的 kubeconfig（按需生成，别分发 admin.conf）
# 注意：/etc/kubernetes/super-admin.conf 属 system:masters，绕过 RBAC，应移走
```

---

## 8. 控制面与 etcd

### 8.1 控制面

```bash
# 静态 Pod 清单目录（改配置就是改这里，kubelet 自动重建）
sudo ls -l /etc/kubernetes/manifests/
#   etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml  kube-vip.yaml

# 改了清单后确认已生效（看 Pod 的 AGE 是否归零）
kubectl -n kube-system get pods -o wide | grep -E "apiserver|etcd|scheduler|controller"

# 组件日志
kubectl -n kube-system logs kube-apiserver-k8s-master-01 --tail=100          # [本环境]
kubectl -n kube-system logs kube-controller-manager-k8s-master-01 --tail=50
kubectl -n kube-system logs kube-scheduler-k8s-master-01 --tail=50

# 组件启动参数（排错时确认 flag 是否真的加上去了）
kubectl -n kube-system get pod kube-apiserver-k8s-master-01 -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n'
sudo grep -E "^\s+- --" /etc/kubernetes/manifests/kube-apiserver.yaml

# 备份当前控制面配置（改之前必做）
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml{,.bak.$(date +%F-%H%M)}
```

### 8.2 VIP（kube-vip）

```bash
# 当前持有者
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
kubectl -n kube-system get lease plndr-cp-lock -o yaml | grep -E "holderIdentity|renewTime|leaseDuration"

# 哪个节点上真的绑了 VIP（在每台执行，只有一台有输出）
ip -4 addr show ens160 | grep -w 192.168.1.100

# VIP 是否可达
ping -c3 192.168.1.100
curl -k -s -o /dev/null -w "%{http_code}\n" https://192.168.1.100:6443/healthz   # 401/403 都算通

# 从集群外验证（在 Mac 上）
nc -zv 192.168.1.100 6443

# kube-vip 日志
kubectl -n kube-system logs <kube-vip-pod> --tail=50
kubectl -n kube-system get pods -l app=kube-vip -o wide

# 漂移原理：租约 5s 续期，持有者失联后其他节点抢锁
#   演练方式：关机当前持有者 → 15s 内应在新节点绑上 VIP（需在 VMware 里开机回来）
```

### 8.3 etcd

```bash
# 统一变量（避免每次打一长串）
ETCD="sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

# 成员列表（应 3 个 started）
$ETCD member list -w table

# 各成员健康与角色
$ETCD endpoint status -w table          # 看 IS LEADER / RAFT INDEX / DB SIZE
$ETCD endpoint health -w table

# 关键一致性判断：三个成员的 RAFT INDEX 应基本一致
#   index 差距持续扩大 → 某成员落后，网络或磁盘有问题
#   DB SIZE 超过 2GB   → 需要 defrag + 调大 quota

# 告警（有 NOSPACE 就必须立刻处理）
$ETCD alarm list

# 键空间概览（不要在生产随意 get --prefix /）
$ETCD get /registry --prefix --keys-only --limit=20

# 碎片整理（逐个成员做，会短暂阻塞，别同时）
$ETCD defrag --command-timeout=60s

# 数据目录大小（对比 DB SIZE 判断碎片程度）
sudo du -sh /var/lib/etcd
sudo ls -lh /var/lib/etcd/member/snap/db

# etcd 日志
kubectl -n kube-system logs etcd-k8s-master-01 --tail=50 | grep -iE "error|warn|slow"

# 关键性能指标（commit 延迟 > 100ms 说明磁盘慢）
kubectl -n kube-system logs etcd-k8s-master-01 | grep -E "commit.*took|apply.*took" | tail -10
```

### 8.4 etcd 快照与恢复

```bash
# ---------- 备份（本环境已有每日 2:00 定时任务）----------
sudo mkdir -p /var/backups/etcd
SNAP=/var/backups/etcd/snap-$(date +%F-%H%M).db
sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save $SNAP

# 校验快照（必做，不能只看文件大小）
sudo env ETCDCTL_API=3 etcdctl snapshot status $SNAP -w table
# 关注：hash 非 0、totalKey 合理、totalSize 与集群规模匹配

# 手动触发已有备份脚本
sudo /usr/local/bin/etcd-backup.sh
sudo ls -lh /var/backups/etcd/

# ---------- 恢复（灾难场景，务必先在测试环境演练）----------
# 前置：三台 kubelet 全停，避免静态 Pod 反复拉起
#   sudo systemctl stop kubelet        # 三台都执行

# 每台分别执行，--name / --initial-advertise-peer-urls / --data-dir 各不相同
sudo env ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd/<snap>.db \
  --name k8s-master-01 \
  --initial-cluster k8s-master-01=https://192.168.1.101:2380,k8s-master-02=https://192.168.1.102:2380,k8s-master-03=https://192.168.1.103:2380 \
  --initial-cluster-token etcd-cluster-restore \
  --initial-advertise-peer-urls https://192.168.1.101:2380 \
  --data-dir /var/lib/etcd-restore

# 把 etcd 静态 Pod 的数据目录指到新目录
sudo vi /etc/kubernetes/manifests/etcd.yaml
#   hostPath.path: /var/lib/etcd  →  /var/lib/etcd-restore
#   注意 volumes 与 volumeMounts 两处都要改

# 启动 kubelet 并验证
sudo systemctl start kubelet
kubectl -n kube-system get pods | grep etcd
$ETCD endpoint health -w table
```

> 恢复演练的价值远大于备份本身。**没演练过的备份等于没有备份**——这是巡检报告里 P1-7 的核心判断。

---

## 9. containerd 与镜像

### 9.1 crictl（kubelet 视角，排错主力）

```bash
# 配置端点（只配一次）
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock

# 容器
sudo crictl ps                       # 运行中
sudo crictl ps -a                    # 含已退出（排错必用）
sudo crictl ps -a --name kube-apiserver
sudo crictl ps -a --state exited
sudo crictl inspect <container-id> | head -50
sudo crictl logs <container-id>
sudo crictl logs --tail=100 <container-id>
sudo crictl stats                    # 实时 CPU/内存/IO
sudo crictl stop <container-id>
sudo crictl rm <container-id>

# Pod（沙箱）
sudo crictl pods
sudo crictl pods --name web-xxx
sudo crictl inspectp <pod-id>

# 镜像
sudo crictl images
sudo crictl images | grep -c .
sudo crictl inspecti <image>
sudo crictl pull nginx:1.27
sudo crictl pull --creds user:pass registry.example.com/app:v1
sudo crictl rmi <image-id>
sudo crictl rmi --prune              # 清理未使用镜像（磁盘满时用）

# 运行时信息
sudo crictl info | head -40          # 看 cgroup driver、runtime 版本
sudo crictl version
```

### 9.2 ctr（containerd 原生，能做的事更多）

```bash
# 命名空间必须指定，kubelet 用 k8s.io
sudo ctr -n k8s.io images ls
sudo ctr -n k8s.io containers ls
sudo ctr -n k8s.io tasks ls

# 带镜像源配置拉取（验证 hosts.toml 是否配对了）
sudo ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d ghcr.io/kube-vip/kube-vip:v0.8.9

# 导出镜像（离线分发用）
sudo ctr -n k8s.io images export /tmp/nginx.tar nginx:1.27
sudo ctr -n k8s.io images import /tmp/nginx.tar

# 清空未使用镜像
sudo ctr -n k8s.io content prune references

# 注意：ctr 与 crictl 的镜像列表可能不一致——kubelet 拉的是 k8s.io 命名空间
```

### 9.3 镜像加速验证（本环境专用排查链）

```bash
# 配置目录（containerd 2.x 必须是单目录，冒号分隔会静默失效）
grep -n "config_path" /etc/containerd/config.toml
#   正确：config_path = '/etc/containerd/certs.d'
#   错误：config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'   ← 会导致整个加速失效

# 各 registry 的 hosts.toml
ls -l /etc/containerd/certs.d/*/hosts.toml
cat /etc/containerd/certs.d/docker.io/hosts.toml
#   不要写 server = "https://docker.io"，否则仍会走原站

# 三条验证（缺一不可，只看 ctr 通过不算数）
sudo crictl pull docker.io/library/busybox:1.36        # ① kubelet 路径
sudo ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d docker.io/library/busybox:1.36   # ② 直连路径
sudo journalctl -u containerd --since "2 min ago" | grep -iE "hosts.toml|trying|mirror"   # ③ 日志确认走了镜像源

# 改完重启（containerd 必须重启才读 hosts.toml）
sudo systemctl restart containerd
sudo systemctl is-active containerd
```

### 9.4 磁盘满导致 Pod 起不来

```bash
# 定位
df -h /var/lib/containerd /var/lib/kubelet /
sudo du -sh /var/lib/containerd/*
sudo du -sh /var/log/* | sort -rh | head

# 清理（按安全顺序）
sudo crictl rmi --prune                              # 未使用镜像
sudo journalctl --vacuum-size=500M                   # 日志
sudo find /var/log -name "*.gz" -mtime +7 -delete    # 归档日志
sudo ctr -n k8s.io content prune references

# kubelet 自带 GC（确认阈值，避免误删正在用的镜像）
grep -E "imageGCHighThresholdPercent|imageGCLowThresholdPercent|evictionHard" /var/lib/kubelet/config.yaml
```

---

## 10. 资源与容量

```bash
# 需要 metrics-server（本集群尚未安装，见 P1-4）
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20
kubectl top pods -A --sort-by=cpu | head -20
kubectl top pod <pod> --containers

# 没装 metrics-server 时的替代（读 kubelet cAdvisor，无需额外组件）
kubectl get --raw /api/v1/nodes/k8s-master-01/proxy/stats/summary | python3 -m json.tool | head -40

# 节点分配率（requests vs allocatable）
kubectl describe node k8s-master-01 | sed -n '/Allocated resources/,/Events/p'

# 全集群 requests/limits 汇总（容量规划核心）
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{.resources.requests.memory}{"\n"}{end}{end}' | sort | uniq -c | sort -rn | head

# 找出没设 requests/limits 的 Pod（隐患，两个字段都为空时会显示 "/"）
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.cpu}{"/"}{.spec.containers[*].resources.requests.memory}{"\n"}{end}' | awk -F'\t' '$2=="/"'

# QoS 等级分布（Guaranteed 最抗压，BestEffort 最先被驱逐）
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,QOS:.status.qosClass | sort -k3

# 驱逐顺序：BestEffort → Burstable（超 requests）→ Guaranteed
# 检查节点驱逐阈值
grep -A5 evictionHard /var/lib/kubelet/config.yaml

# HPA
kubectl get hpa -A
kubectl describe hpa web
```

---

## 11. 备份与升级

### 11.1 备份清单（本集群现状）

| 对象 | 位置 | 频率 | 命令 |
|---|---|---|---|
| etcd 快照 | `/var/backups/etcd/` | 每日 2:00 | `sudo /usr/local/bin/etcd-backup.sh` |
| PKI 证书 | `/root/k8s-pki-*.tar.gz` | 变更后 | 见下 |
| 控制面清单 | `/etc/kubernetes/manifests/` | 变更后 | `sudo tar czf` |
| 集群对象 | `kubectl get all -A -o yaml` | 每周 | 见下 |
| kubeconfig | `/etc/kubernetes/admin.conf` | 变更后 | — |

```bash
# PKI 打包（丢了 CA 就等于集群无法恢复）
sudo tar czf /root/k8s-pki-$(date +%F).tar.gz \
  -C /etc/kubernetes pki etcd/ca.crt etcd/ca.key etcd/server.crt etcd/server.key admin.conf

# 全量对象导出（不含 Secret 明文时加过滤）
kubectl get all,cm,secret,pvc,ingress,networkpolicy -A -o yaml > /tmp/cluster-objects-$(date +%F).yaml

# 定期任务检查
sudo crontab -l
sudo ls /etc/cron.d/
```

### 11.2 版本升级（1.34 → 1.35 示例）

```bash
# 顺序铁律：先升控制面，再升 kubelet/kubectl；一次只升一个 minor

# ① 解除 hold（本环境已 hold）
sudo apt-mark unhold kubeadm

# ② 升 kubeadm
sudo apt-get update && sudo apt-get install -y kubeadm=1.35.x-1.1
sudo apt-mark hold kubeadm

# ③ 看能升什么
sudo kubeadm upgrade plan

# ④ 第一个控制面节点：apply
sudo kubeadm upgrade apply v1.35.x

# ⑤ 其余控制面节点：node（不是 apply）
sudo kubeadm upgrade node

# ⑥ 逐台 drain → 升 kubelet/kubectl → uncordon
kubectl drain k8s-master-02 --ignore-daemonsets --delete-emptydir-data
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.35.x-1.1 kubectl=1.35.x-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon k8s-master-02

# ⑦ 验证
kubectl get nodes -o wide
kubectl -n kube-system get pods
```

### 11.3 节点重新加入

```bash
# 生成 join 命令（worker）
kubeadm token create --print-join-command

# 控制平面节点需要证书 key
sudo kubeadm init phase upload-certs --upload-certs
kubeadm token create --print-join-command --certificate-key <key>
#   注意 1.34 起 --config 与 --certificate-key 不能混用，key 要写进配置文件 certificateKey 字段

# 重置单节点（会清空该节点 K8s 状态）
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/etcd
sudo systemctl restart containerd kubelet

# 从集群中彻底移除一个 etcd 成员（谨慎，会导致 quorum 变化）
$ETCD member list -w table
$ETCD member remove <member-id>
```

---

## 12. 高频 JSONPath 与自定义列模板

> 运维效率的分水岭：会不会用 `-o jsonpath` / `custom-columns` 替代 `grep`。

```bash
# 节点：名称 + 内网 IP + 角色
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address,\
ROLE:.metadata.labels.node-role\\.kubernetes\\.io/control-plane

# Pod：名称 + 节点 + PodIP + QoS
kubectl get pods -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,\
IP:.status.podIP,QOS:.status.qosClass

# Pod：镜像 + 重启次数 + 上次退出码
kubectl get pods -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,\
IMAGE:.spec.containers[0].image,\
RESTARTS:.status.containerStatuses[0].restartCount,\
EXIT:.status.containerStatuses[0].lastState.terminated.exitCode

# 所有镜像及使用次数（清理/预热用）
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort | uniq -c | sort -rn

# 容器名列表（logs -c 前先查）
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}{"\n"}'

# 节点上 Pod 的 requests 合计（判断还能塞多少）
kubectl get pods -A --field-selector spec.nodeName=k8s-master-01 \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{","}{.resources.requests.memory}{"\n"}{end}{end}'

# Service → 后端 Pod IP
kubectl get endpoints web -o jsonpath='{.subsets[*].addresses[*].ip}{"\n"}'

# 所有 PVC 及绑定状态
kubectl get pvc -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName,\
CAP:.status.capacity.storage,STATUS:.status.phase

# 事件按对象聚合（找热点）
kubectl get events -A -o jsonpath='{range .items[*]}{.involvedObject.name}{" "}{.reason}{"\n"}{end}' | sort | uniq -c | sort -rn | head

# 给所有节点打标签
kubectl get nodes -o name | xargs -I{} kubectl label {} env=test --overwrite

# 批量删除某状态的 Pod
kubectl get pods -A --field-selector status.phase=Failed -o name | xargs -r kubectl delete

# 批量删除 Evicted（reason 不是合法 field-selector，用 jsonpath 过滤）
kubectl get pods -A -o jsonpath='{range .items[?(@.status.reason=="Evicted")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
  | xargs -r -n2 sh -c 'kubectl -n $0 delete pod $1'
```

---

## 13. 高危命令红黑榜

### 不可逆 / 影响面极大（执行前必须二次确认）

| 命令 | 后果 | 更安全的做法 |
|---|---|---|
| `kubectl delete namespace <ns>` | 命名空间内所有资源永久删除，**无法撤销** | 先 `kubectl get all -n <ns>` 确认；重要环境先备份 YAML |
| `kubectl delete crd <crd>` | 该 CRD 下**所有**自定义资源一起消失（含 Calico 网络配置） | 先 `kubectl get <cr> -A` 看清规模 |
| `kubectl delete pv <pv>` | 数据丢失（取决 reclaimPolicy） | 先确认 `kubectl get pv <pv> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'` |
| `kubectl apply --prune` | 会删除清单里没有的对象 | 加 `--prune-whitelist` 或在测试环境先 dry-run |
| `rm -rf /var/lib/etcd` | 该节点 etcd 数据全毁，成员无法再启动 | 先备份；确认不需要恢复该成员 |
| `kubeadm reset -f` | 清空节点 K8s 状态，Pod 全部消失 | 先 `drain`，确认可重建 |
| `etcdctl member remove` | 永久移除成员，可能丢 quorum | 先 `member list` 确认剩几台 |
| `iptables -F` / `-t nat -F` | 清掉 kube-proxy 与 Calico 规则，**全集群网络中断** | 重启 kube-proxy / calico-node 代替 |
| `systemctl stop kubelet` | 该节点所有 Pod（含静态 Pod）停摆 | 先 `cordon`，业务 Pod 会被重建 |
| `kubectl drain` 控制面节点 | etcd 少一票；本环境再挂一台即失去 quorum | 先确认 VIP 不在此节点、etcd 其余成员健康 |

### 会让机器"变砖"的

```bash
# 不要执行
sudo swapoff -a && sudo sed -i '/swap/d' /etc/fstab      # 误删 fstab 可能导致启动异常
sudo rm -rf /etc/kubernetes/pki                          # CA 丢失后集群无法恢复，重签会全盘失效
sudo sed -i 's/SELinux=enforcing/disabled/' /etc/selinux/config
```

### 安全但要注意时机的

```bash
kubectl rollout restart deploy/x        # 滚动期间容量下降，确认有足够副本
kubectl scale deploy/x --replicas=0     # 业务中断
kubectl delete pod <静态Pod的名字>       # 会被 kubelet 立刻重建（这是正常的）
kubectl edit / patch                    # 改完无法自动回滚，改前先备份 YAML
```

---

## 附录 A 别名与 shell 增强

```bash
# 追加到 ~/.zshrc（或 ~/.bashrc）
export KUBECONFIG=$HOME/.kube/config

# 补全
source <(kubectl completion zsh)
# bash 用：source <(kubectl completion bash)

alias k=kubectl
alias kg='kubectl get'
alias kgp='kubectl get pods -o wide'
alias kga='kubectl get pods -A -o wide'
alias kd='kubectl describe'
alias kl='kubectl logs --tail=100'
alias klf='kubectl logs -f --tail=100'
alias kx='kubectl exec -it'
alias kdel='kubectl delete'
alias ke='kubectl edit'
alias kaf='kubectl apply -f'
alias kns='kubectl config set-context --current --namespace'
alias kctx='kubectl config get-contexts'
alias ktop='kubectl top pods -A --sort-by=memory'

# 常用组合
alias kbad='kubectl get pods -A --field-selector=status.phase!=Running'
alias kevents='kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -30'
alias kvip='kubectl -n kube-system get lease plndr-cp-lock -o jsonpath="{.spec.holderIdentity}{\"\n\"}"'

# 让 k 也能用补全
compdef _kubectl k 2>/dev/null || complete -F _kubectl k
```

**三个容易踩的环境坑（本集群实测）**

```bash
# ① sudo kubectl 一定失败 —— root 的 HOME 里没有 kubeconfig
sudo kubectl get nodes
#   → The connection to the server localhost:8080 was refused
# 正确写法（二选一）
sudo -E kubectl get nodes                                     # 继承当前 KUBECONFIG
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes

# ② --field-selector 只支持少数字段，写错会静默返回空
kubectl get pods -A --field-selector reason=Evicted            # 不报错，但结果不可信
#   Pod 支持的字段仅：metadata.name / metadata.namespace / spec.nodeName /
#                    spec.restartPolicy / spec.schedulerName / status.phase / status.podIP
# 其他条件一律用 jsonpath 或 -o json 过滤

# ③ 容器镜像极简（calico 用 runit 基础镜像），容器内没有 head/grep 等常用命令
#   不要写 kubectl exec $POD -- sh -c 'xxx | head'
#   管道放到宿主机侧：kubectl exec $POD -- xxx | head
```

**推荐插件**（可选，按需装）

| 工具 | 作用 | 安装 |
|---|---|---|
| `stern` | 多 Pod 日志聚合，一条命令看整个 Deployment | `brew install stern` |
| `kubectx` / `kubens` | 切换 context / namespace | `brew install kubectx` |
| `k9s` | 终端 UI，日常浏览效率高 | `brew install k9s` |
| `krew` | kubectl 插件管理器 | `brew install krew` |
| `calicoctl` | Calico 完整管理（本集群目前用 kubectl 直查 CRD 也能覆盖） | 单独下载二进制 |

---

## 附录 B 按症状查命令

| 症状 | 命令 | 章节 |
|---|---|---|
| 不知道该看什么 | `kubectl get pods -A --field-selector=status.phase!=Running` | 0 |
| 节点 NotReady | `systemctl status kubelet` + `journalctl -u kubelet -n 50` | 1.5 |
| Pod 一直 Pending | `kubectl describe pod` 看 Events；查污点/资源/PVC | 3.2 |
| Pod 一直 ContainerCreating | `describe` + 节点 `crictl ps -a` + CNI 状态 | 3.2 |
| 反复重启 | `kubectl logs <pod> --previous` | 2.2 / 3.2 |
| 镜像拉不下来 | `describe` 看 image → 节点 `crictl pull` | 9.3 |
| 服务访问不到 | `get endpoints`（空 = selector/ready 问题） | 3.4 |
| DNS 解析失败 | `nslookup 全名` + `cat /etc/resolv.conf` | 4.2 |
| 跨节点不通 | `ip -br addr show tunl0` + `calico-node -felix-ready` + `birdcl show protocols` | 4.3 |
| API 连不上 | `ping VIP` + `kubectl -n kube-system get lease plndr-cp-lock` | 8.2 |
| etcd 异常 | `etcdctl endpoint status -w table` + `alarm list` | 8.3 |
| 磁盘满 | `df -h` + `crictl rmi --prune` | 9.4 |
| 403 Forbidden | `kubectl auth can-i --list --as=...` | 7.1 |
| 证书过期 | `kubeadm certs check-expiration` | 7.2 |
| 改配置不生效 | 确认 subPath 挂载 → `rollout restart` | 6 |
| PVC Pending | `describe pvc` + `kubectl get sc`（本集群无 SC） | 5 |
| Pod 删不掉 | 查 finalizer → `patch --type=merge` | 3.3 |
| 内存/CPU 看不清 | `kubectl top` 或 `kubectl get --raw .../stats/summary` | 10 |

---

## 附录 C 本集群固定参数

| 项目 | 值 |
|---|---|
| API 入口 | `https://192.168.1.100:6443`（VIP，kube-vip v0.8.9） |
| 节点 | `k8s-master-01` .101 / `k8s-master-02` .102 / `k8s-master-03` .103 |
| 网卡 | `ens160` |
| 网关 / DNS | `192.168.1.1` |
| DNS 域 | `ai4system.com` |
| Pod 网段 | `10.244.0.0/16`（Calico v3.33，IPIP `tunl0`） |
| Service 网段 | `10.96.0.0/12`，ClusterIP 首个 `10.96.0.1`，CoreDNS `10.96.0.10` |
| 容器运行时 | containerd 2.2.1（`SystemdCgroup=true`） |
| pause 镜像 | `registry.aliyuncs.com/google_containers/pause:3.10` |
| 静态 Pod 清单 | `/etc/kubernetes/manifests/` |
| etcd 数据 | `/var/lib/etcd`（DB 约 7.8MB） |
| etcd 备份 | `/var/backups/etcd/`，cron `/etc/cron.d/etcd-backup` 每日 2:00 |
| PKI 备份 | `/root/k8s-pki-*.tar.gz` |
| 镜像加速 | docker.io → `docker.m.daocloud.io`；quay.io → `quay.m.daocloud.io`；ghcr.io → `ghcr.m.daocloud.io` |
| 认证 | 三台均为 `lumz/lumz1021`（**仅测试环境**） |
| 巡检脚本 | `scripts/k8s_inspect_cluster.sh`、`scripts/host_inspect.sh`（`SUDO_PW` 传密码） |

---

## 变更记录

| 日期 | 说明 |
|---|---|
| 2026-10-30 | 初版。按场景组织，13 章 + 3 附录；参数按实测集群填写；含五步排错法、Pod 状态字典、高危命令红黑榜、症状反查索引。其中 Calico 健康检查、IPAM 统计、Event TTL、`sudo kubectl` 等 6 处易错写法已在 k8s-master-01 实机验证并修正 |
