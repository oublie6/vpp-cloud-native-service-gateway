# Goal 004：双逻辑节点 Service Dataplane / Recovery / Observability / Software Benchmark

状态：Codex 已实现并通过单机双逻辑节点/kind/VPP 实测；待 ChatGPT 学习 / 工程验收。

## 背景与学习重点

Goal 003 已证实 Kubernetes Service/EndpointSlice 经 informer、desired store、GoVPP 驱动 VPP CNAT，并通过 TCP/UDP packet E2E。Goal 004 验证一个本地 backend 与一个跨路由边界的远端 backend 同时存在时的正反向路径、失效收敛和可观测性。原 Goal 004 实施时只有一台普通云服务器，因此既有“双节点”证据是网络命名空间隔离的**两个逻辑节点**；不能表述成两台真实主机、真实 NIC 或 line-rate。2026-10-14 另用临时 SSH TUN 在现有第二台物理主机上验证了补充数据路径；Kubernetes worker 仍未 Ready，详见[结果](../../results/goal004/README.md)。

## 固定环境和边界

- Ubuntu 20.04、kernel 5.4.0-216-generic；VPP 24.10-release；GoVPP v0.13.0；Go 1.24.13；Kubernetes v1.33.1/client-go v0.33.1/kind v0.29.0。
- 入口节点为 Goal 001 独立 VPP + `tap101/tap102`。Goal 004 只在 Goal 001 拥有的 namespace 中添加可清理的 veth/router 设置，并创建一个独立 `g004-remote` namespace 作为远端节点。
- 隔离 VIP 继续使用 Goal 003 的 `198.19.0.20:18080`，普通 Kubernetes ClusterIP 仍由 kube-proxy 处理。VPP FIB 的远端 backend 路由通过 GoVPP Binary API 写入/删除。
- 不改宿主管理 NIC、默认 route、全局 firewall、VFIO、DPDK 或 kube-proxy；不做真实多机性能声称。

## 预期拓扑

```text
g001-client 10.10.1.2
    | Goal001 TAP
VPP tap101 10.10.1.1 -> CNAT VIP 198.19.0.20:18080
    |
VPP tap102 10.10.2.1
    | Goal001 TAP
g001-server 10.10.2.2 (local backend + router, 10.10.3.1/30)
    | Goal004 veth
g004-remote 10.10.3.2/30 + remote backend 10.10.4.2/32
```

VPP 对 `10.10.4.2/32` 的下一跳是 `10.10.2.2`；remote 的反向路由经 `g001-server` 回到 VPP。`net.ipv4.ip_forward` 仅在 Goal 001 创建的 `g001-server` namespace 内设置，设置前记录原值，cleanup 后连同 namespace 消失。

## Stage A：两 backend 的真实路径

1. 建立可重复 setup/cleanup 的双逻辑节点拓扑，采集前后 host/netns/VPP 状态，拒绝接管预存资源。
2. 通过 GoVPP 添加/删除远端 `/32` FIB route，并复查 VPP actual FIB；不将 VPP CLI 用作正式控制面。
3. 在隔离 kind API server 中创建 opt-in Service 与 local/remote EndpointSlice；controller 驱动 CNAT；TCP/UDP 新 flow 应分别命中两个 backend，源端看到 VIP reply peer。采集正向/反向 trace、route、adjacency、neighbor、Stats API counter。

门槛：真正穿越 VPP 和远端 veth/router 的 packet E2E；能证明远端 next-hop、complete adjacency 和反向路径。若实际输出缺某项，明示等价证据。

## Stage B：backend 与故障收敛

1. EndpointSlice ready/terminating 改变时，controller 更新 CNAT；新 flow 避开已移除 backend。记录已有 session 的实际行为。
2. 隔离远端链路故障时，记录 packet failure 与 VPP/error counter；恢复链路并更新 EndpointSlice 后，新 flow 恢复。
3. controller、VPP/API server 的已验证恢复机制保持可用；至少复验一次远端场景下的重试/收敛。

门槛：故障不产生“控制面宣称成功但 VPP actual 不符”的永久状态；恢复后 packet E2E 成功。

## Stage C：观测与有界软件测量

1. 暴露 controller 的 reconcile attempts/failures/changes 及最近一次成功/失败状态，明确只监听 loopback；验证指标随事件和失败增长。
2. 使用受控 Python generator 进行小规模、有限时长的 TCP/UDP software 测量，记录 CPU、worker、packet 大小、flow 数、offered load、RX/TX/drop、runtime node vectors、是否穿越 Linux kernel/TAP/veth。结果仅说明本机实验，不用于 throughput 性能结论或 line-rate 声称。
3. 清理 kind、Docker bridge、TAP、namespace、route、CNAT 与临时文件；对照 host 默认 route、管理接口、已有容器和必要 sysctl。

门槛：观测指标和测量元数据完整，`go test ./...`、`go vet ./...`、shell/Python syntax、`git diff --check` 通过；没有实验 host state 残留。

## Non-goals

- 原 Goal 004 实验不引入真实第二台主机、DPDK NIC、TRex、RSS、worker handoff 或多 worker 调优。用户后续指定了现有第二台主机；其补充验证须单独记录，不能追认原逻辑节点证据为物理跨主机验收。
- 不实现自动健康检查器；EndpointSlice readiness 是上游健康信号，Goal 004 验证其收敛效果。
- 不实现自定义 VPP plugin；留待 Goal 005。

## Codex 实现记录

### Stage A：local/remote backend

新增 `scripts/goal004/setup-remote.sh`、`cleanup-remote.sh` 和集中命名文件，在 Goal 001 TAP 基础上建立 `g001-server` 路由器与 `g004-remote` veth/namespace。新增 `cmd/goal004-route`，以 GoVPP Binary API 对 `10.10.4.2/32 via 10.10.2.2 tap102` add/del/dump 并复查；对非本 Goal 路由拒绝覆盖。kind 中的 opt-in Service/EndpointSlice 驱动 Goal 003 controller，TCP/UDP 双 backend packet E2E 成功，真实 VPP trace 包含远端 session 正反向改写。FIB、next-hop neighbor、complete adjacency、Stats API 证据见 [结果](../../results/goal004/README.md)。

### Stage B：链路故障、scale 和重启

远端 veth down 后已有远端 UDP session 超时、VPP `null-node blackholed packets` 增 2；EndpointSlice `ready=false` 后 10 条新 flow 均到本地。恢复链路时发现 Linux 自动移除远端默认路由，脚本补回并复验 L3，再将 endpoint 标回 ready；20 条新 flow 在两个 backend 各 10 条。VPP/GoVPP 重启场景中，controller 在 VPP socket 缺失期间真实记录 3 次失败，随后重建两协议 translation，local/remote TCP/UDP 再次 E2E 成功。VPP 24.10 在 CNAT backend 先于 API route 出现时可能形成 drop FIB entry；route 程序仅确认它属于本实验 VIP/backend 时才添加 next-hop。

### Stage C：观测、测量和 cleanup

controller 新增 loopback `/metrics`、`/status`，反映 attempts/failures/changes 与最近成功/失败时间；测试中 failures 从 0 到 3，恢复后的 success 时间晚于 failure。采用 Python 有界、限速的软件生成器验证各 100 条 TCP/UDP flow，应用 payload 128 B，目标 offered load 200 flows/s，记录 CPU/NUMA、VPP main thread、TAP Stats API 前后、runtime vectors、error counters。其结果只作为 software evidence，不做吞吐/line-rate 结论。测试脚本 cleanup 后，VPP 仅 `local0`、CNAT translation/session 0；kind 和空 Docker bridge 删除，host state 前后完整 diff 为零。远端 setup/cleanup 重复执行验证通过。

### 后续补充：真实物理主机

新增 `scripts/goal004/test-physical-ssh-tun.sh`，在用户指定的美国节点上用临时 SSH/TCP TUN 连接既有 VPP TAP 拓扑。真实 Kubernetes control-plane 的 Service/EndpointSlice 经本机 controller/GoVPP 驱动 CNAT；跨云主机 host loopback backend 的 TCP/UDP、正反向 trace、readiness 收敛和恢复通过，脚本从干净环境复跑及自动 cleanup 退出码 0。用户确认本机就是集群中的 `hk-worker`；其旧 Node 状态与本机当前 OS/kernel/kubelet 状态不一致，且仍为 `NotReady`。该补充没有修复既有 WireGuard 链路或恢复 worker，故不能宣称两个 Ready Kubernetes 节点上的 Pod E2E。详细结果及恢复前提见 [Goal 004 证据](../../results/goal004/README.md)。

用户随后授权恢复本机环境：已安装 Ubuntu 20.04 HWE kernel 5.15、重启并复验 VPP 24.10/Goal 001 TAP dataplane，安装并固定与控制平面一致的 kubelet/kubeadm/kubectl v1.36.4；containerd 的 CRI `runc` 已改为与集群 kubelet 一致的 `systemd` cgroup driver，重启后两个既有 Docker 容器和 VPP 状态不变。`hk-worker` 尚未入群；美国节点发往本机公网 UDP 51820 的探测包未到达 `eth0`，WireGuard 仍无握手。未删除旧 Node 或现有 Pod。实际 host state、安装和失败证据见 [Goal 004 证据](../../results/goal004/README.md)。

用户开放安全组后的双端同步抓包进一步显示：本机 WireGuard 握手在公网侧经 NAT 改写源端口，美国节点发出对应回复，但回复仍未到达本机 `eth0`；同方向 TCP 22 入站成功。故需排查本机公网 UDP 的 NAT 回程或上游过滤，具体规则尚未定位；在该路径恢复前，不能将 `hk-worker` 标成 Ready 或声称真实双节点 Pod E2E 已通过。

## ChatGPT 学习 / 工程验收

待验收。

## 一手资料

- [FD.io VPP 24.10 Cloud NAT](https://docs.fd.io/vpp/24.10/developer/plugins/cnat.html)
- [Kubernetes EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
