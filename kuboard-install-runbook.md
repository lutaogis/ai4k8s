# Kuboard v4 + Headlamp 安装运维手册（k8s-prod-ha 集群）

> Kuboard 安装：2026-10-31 00:20 CST · Headlamp 安装：2026-10-31 00:55 CST · 两者并存于同一集群
>
> **本文件是速查卡**：完整版（安装全过程、使用手册、菜单与 kubectl 对照、5 个踩坑、安全整改项）已并入 `k8s-ops-commands.md` **第 14 章**，两处冲突时以运维手册为准。

## 1. 访问信息

| 项 | 值 |
|---|---|
| Web 入口 | **http://192.168.1.100:30080**（经 VIP，任意节点 30080 均可） |
| 初始账号 | admin / **Kuboard123**（登录后 3 天内强制改密，请立即改） |
| 集群命名空间 | `kuboard`（已打 PSA enforce: baseline） |
| 已导入集群 | k8s-prod-ha（kubeconfig 方式，apiServerUrl=https://192.168.1.100:6443） |

## 2. 架构与组件

| 组件 | 说明 |
|---|---|
| `kuboard` Deployment ×1 | Kuboard v4 服务端（镜像 `swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v4`），端口 80，NodePort 30080 |
| `kuboard-db` Deployment ×1 | MariaDB 11.3.2（同仓库镜像），Service `kuboard-db:3306` |
| `kuboard-mariadb-pv` / PVC | hostPath `/data/kuboard-mariadb`（master-01），5Gi，Retain |
| 导入方式 | **v4 无 Agent**：直接用 admin.conf 的证书三件套导入，Kuboard 服务端直连 apiserver 做全量+增量同步 |

## 2b. Headlamp（官方推荐的 K8s Web UI）

| 项 | 值 |
|---|---|
| Web 入口 | **http://192.168.1.100:30081**（NodePort 30081，与 Kuboard 的 30080 并存） |
| 登录方式 | ServiceAccount Token（长效 token 存于集群 Secret `headlamp/headlamp-admin-token`，本地副本 `.workbuddy/reports/headlamp-admin-token.txt`） |
| 权限 | SA `headlamp/headlamp` 绑定 cluster-admin（CRB `headlamp-admin-binding`）—— 实验配置，生产应改最小权限 |
| 部署 | helm chart 本地包 `headlamp-0.46.0.tgz`（GitHub Releases 国内直连被断，本地下载后上传安装），ns `headlamp`，单副本 |
| 背景 | Kubernetes Dashboard 已于 2026-01 归档，K8s 官方推荐 Headlamp 为继任者；Apache 2.0 开源 |
| 镜像 | `ghcr.io/headlamp-k8s/headlamp`（走 daocloud 加速，certs.d 已配置） |

```bash
# 升级 / 卸载
helm -n headlamp upgrade headlamp /tmp/headlamp-0.46.0.tgz --reuse-values
helm -n headlamp uninstall headlamp && kubectl delete ns headlamp
```

## 3. 安装中的三个坑（复装必读）

1. **集群 DNS 域不是 `cluster.local`**：kubeadm `clusterDomain=ai4system.com`，集群内 Service FQDN 为 `kuboard-db.kuboard.svc.ai4system.com`。写 `svc.cluster.local` 会 UnknownHostException。
2. **mariadb 11.3 镜像没有 `mysqladmin`**：exec 型探针会报 executable not found，Pod 永不 Ready。已改用 tcpSocket 探针。
3. **hostPath 单副本滚动更新的文件锁**：maxSurge 会让新旧 DB Pod 短暂并存，第二个 Pod 拿不到 aria/innodb 文件锁而 CrashLoop。改配置更新 DB Pod 时，先 `--replicas=0` 再扩回 1。

清单文件：`kuboard-v4-install.yaml`（工作区根目录，已含上述修正）。

## 4. 常用运维

```bash
# 状态
kubectl -n kuboard get pods,svc
kubectl -n kuboard logs deploy/kuboard --tail=50

# 重启服务端
kubectl -n kuboard rollout restart deploy/kuboard

# 升级 kuboard 镜像版本（DB 无需动）
kubectl -n kuboard set image deploy/kuboard kuboard=swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v4.x

# 数据备份（在 master-01 上）
sudo tar czf /root/kuboard-db-backup-$(date +%F).tgz -C /data kuboard-mariadb

# 完整卸载
kubectl delete -f kuboard-v4-install.yaml   # 或 kubectl delete ns kuboard && kubectl delete pv kuboard-mariadb-pv
sudo rm -rf /data/kuboard-mariadb           # master-01 上清理数据（需确认）
```

## 5. 安全注意事项

- 当前为 **HTTP 明文**，仅限内网实验使用；上生产需在入口做 TLS（Ingress/nginx 反代，WebSocket 需放行）。
- `admin.conf` 的 cluster-admin 凭据存于 Kuboard 数据库（MariaDB），master-01 的 `/data/kuboard-mariadb` 需要当作敏感数据保护。
- Kuboard 所在 Pod 与控制面同机运行，注意资源占用（已设 requests 100m/256Mi、limits 1C/1Gi ×2）。
