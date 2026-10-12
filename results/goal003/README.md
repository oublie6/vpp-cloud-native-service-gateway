# Goal 003 运行证据

状态：Codex 已实现并通过真实 kind/VPP packet E2E 与恢复验证；ChatGPT 学习 / 工程验收待验收。

## 固定环境

| 项目 | 实际值 |
| --- | --- |
| OS / kernel | Ubuntu 20.04 focal / 5.4.0-216-generic |
| VPP | 24.10-release，独立 `/run/vpp-goal001/{cli,api}.sock` |
| GoVPP | v0.13.0；CNAT 所需 message CRC 与当前 VPP API JSON 一致，连接时再次检查 |
| Go | 1.24.13 |
| Kubernetes client | k8s.io/api、apimachinery、client-go v0.33.1 |
| Kubernetes API server | kind v0.29.0 的 Kubernetes v1.33.1；node 为 `kindest/node:v1.33.1`，官方 digest `sha256:050072256b9a903bd914c0b2866828150cb229cea0efe5892e2b644d5dd3b34f` |
| 隔离 VIP | `198.19.0.0/16`，与 Goal 002 的 `198.18.0.10` 分开 |

## 模型与 fake watch

`go test ./internal/... ./cmd/vpp-service-agent ./cmd/goal003-reconcile` 通过。测试覆盖隔离 VIP、Kubernetes ownership 冲突、EndpointSlice 多片聚合与 ready/terminating 过滤、重复事件不重复写入、backend 增删、Service 删除、部分失败后重试和 API 虚假成功检测。`go vet ./...` 通过。

## 真实 VPP adapter

VPP 运行时 `go run ./cmd/goal002-inspect` 报告 `CNAT translations=0 sessions=0`。随后用 Goal 003 `198.19.0.20:18080` 和两个真实后端地址执行 JSON desired snapshot：

```text
reconciled services=2 changed=2 verified=true    # TCP/UDP 新增
reconciled services=2 changed=0 verified=true    # 重复快照，不重复写入
reconciled services=2 changed=2 verified=true    # 两协议增加第二后端
```

`show cnat translation` 观察到 TCP、UDP 各一个 `lb:maglev` translation，分别包含 `10.10.2.2:18080`、`10.10.2.3:18080`。测试时未创建 TAP，故输出中的后端 fib-entry 指向 drop；这里只验证控制面写入、读取与幂等，不将其当作 packet E2E 证据。

空快照 cleanup 输出 `reconciled services=0 changed=2 verified=true`。再次运行 Goal 002 inspect 为 `CNAT translations=0 sessions=0`，VPP 仅有 `local0`。

## Goal 002 回归

在为 `service_traffic.py` 增加可选 `--vip` 参数后，重新运行 `scripts/goal002/test-service.sh` 退出码 0。真实 TAP 拓扑上的 TCP/UDP 双后端、动态增删、trace、session 与 cleanup 全部通过；参数默认值仍是 Goal 002 VIP。

## kind / 实际 Kubernetes 链路

kind 镜像通过代理使用 `crane pull --platform linux/amd64` 获取固定 digest，再 `docker load`；原因是宿主 Docker daemon 没有继承 shell 的代理，直接 `kind create` 停在 `docker pull`。这次失败未改变管理网卡或默认 route，随后从本地镜像建立 `goal003` 集群，`kubectl get nodes -o wide` 显示 `goal003-control-plane Ready v1.33.1`。测试前记录 `/tmp/goal003-kind-before.txt`，包含实验相关 netns/link/addr/route、Docker network/container 和 HugePages 值。

复现前先启动 Goal 001 的独立 VPP 实例、确认无实验 TAP、namespace、Goal 003 CNAT 状态，并创建名为 `goal003` 的 kind 集群。集群 kubeconfig 指向该隔离集群，然后运行：

```bash
GOAL003_KUBECTL=/tmp/goal003-kubectl \
GOAL003_KUBECONFIG=/tmp/goal003-kubeconfig \
GOAL003_TEST_RECOVERY=true \
scripts/goal003/test-controller.sh
```

脚本退出码 0，使用 `g001-client/g001tapc (10.10.1.2/24)` → VPP `tap101 (10.10.1.1/24)` → VPP `tap102 (10.10.2.1/24)` → `g001-server/g001taps (10.10.2.2/24, 10.10.2.3/24)`。`vpp-goal003/echo` 的 annotation 指向 `198.19.0.20:18080`，EndpointSlice 初始含 `.2`、`.3` 两后端。controller 在宿主运行，通过 Kubernetes informer 读缓存、由 reconcile 使用 GoVPP Binary API 写 VPP；未关闭 kube-proxy，未改宿主默认 route。

关键真实输出：

```text
Kubernetes -> VPP: TCP/UDP translation 均已创建
udp distribution {'10.10.2.3': 11, '10.10.2.2': 9}
tcp distribution {'10.10.2.2': 12, '10.10.2.3': 8}
Binary API dumps: interfaces=3 IPv4 routes=17 CNAT translations=2 sessions=80
Stats API: tap102 index=1 rx=131 tx=124 rx_errors=0 tx_errors=0
Stats API: tap101 index=2 rx=130 tx=123 rx_errors=0 tx_errors=0
```

客户端校验每个 payload、后端应答地址、源端看到的 VIP reply peer。UDP/TCP 均有真实 packet E2E。初始流量的成功请求 trace 中实际 node 路径：

```text
virtio-input -> ethernet-input -> ip4-input -> ip4-lookup
-> ip4-cnat-tx -> ip4-load-balance -> ip4-rewrite
-> tap102-output -> tap102-tx
```

`show runtime` 关键行：`ip4-cnat-tx Calls=254 Vectors=294 Vectors/Call=1.16`；`ip4-load-balance 136/147/1.08`；`ip4-rewrite 254/294/1.16`；`virtio-input 194832002/333/0.00`。这是低流量机制证据，不做性能结论。`clear errors` 后 `show errors` 仅显示 `arp-reply ARP replies sent` 1 次，severity 为 `info`；未观察到 error severity 计数。

EndpointSlice 删除 `.3` 后，VPP translation 不再包含 `.3`，10 条全新 UDP flow 全到 `.2`。controller 进程重启后，初次全量 cache 同步输出 `services=2 changed=0`，没有重复写 VPP。

VPP 关闭 2 秒期间，controller 记录 3 次 `VPP API socket file /run/vpp-goal001/api.sock does not exist`；VPP 和 Goal 001 TAP 重建后，controller 输出 `services=2 changed=2`，重新创建 TCP/UDP translation，5 条新 UDP flow 全到唯一 `.2` 后端。这里的重新建 TAP 是因为 VPP 重启会销毁原 TAP，而不是另造一套拓扑。

隔离 kind API server 容器重启后，controller 的 Service/EndpointSlice informer 曾记录短暂 `Failed to watch`，错误文本包含 `forbidden` 和先前连接的 `connection reset by peer`。API ready 后将 EndpointSlice 扩回两后端，controller 输出 `services=2 changed=2`，20 条新 UDP flow 分布 `.3` 13 条、`.2` 7 条，证明 watch 重新收敛。此处错误是重启窗口内的真实日志，未隐藏；若非测试重启场景持续出现，需排查认证/权限。

删除 Service 后，controller 输出 `services=0 changed=2`，VPP TCP/UDP translation 均消失。脚本随后删除 `vpp-goal003` namespace、TAP、network namespace 和 CNAT 实验状态；再次检查 VPP `interfaces=1 CNAT translations=0 sessions=0`（仅 `local0`）。

## Host state cleanup

运行 `kind delete cluster --name goal003` 后发现 kind 留下空 `kind` Docker bridge；确认 `docker network inspect kind` 的 containers 为空，且它不在原始网络清单中，再执行 `docker network rm kind`。随后按与测试前完全相同的命令采集 `/tmp/goal003-kind-after.txt`，`diff -u /tmp/goal003-kind-before.txt /tmp/goal003-kind-after.txt` 退出码 0。宿主 `eth0` 仍为 `10.0.138.51/24`，默认路由仍是 `default via 10.0.138.1 dev eth0 proto static`；原有两个 `learn-xray-*` 容器未受影响；`vm.nr_hugepages=0`。无实验 namespace/TAP、CNAT translation/session 留存。

## 测试命令

- `GOTOOLCHAIN=local go test ./...`：通过。
- `GOTOOLCHAIN=local go vet ./...`：通过。
- `bash -n scripts/goal001/*.sh scripts/goal002/*.sh scripts/goal003/*.sh`：通过。
- `python3 -m py_compile scripts/goal002/service_traffic.py`：通过。
- `git diff --check`：通过。
- `scripts/goal002/test-service.sh`：修改流量工具后的原 Goal 回归通过。
- `GOAL003_TEST_RECOVERY=true scripts/goal003/test-controller.sh`：kind + VPP 真实 E2E、重启恢复和 cleanup 通过；完整临时执行日志在 `/tmp/goal003-final-run.log`，仅摘取关键文本进入本仓库。
