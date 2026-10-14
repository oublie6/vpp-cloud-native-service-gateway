# Goal 004 实际运行证据

状态：Codex 已在单机双逻辑节点软件拓扑上实现并验证；ChatGPT 学习 / 工程验收待验收。**本实验不是两台物理主机或真实 NIC 的性能测试。**

## 环境、版本和 ownership

Ubuntu 20.04 focal、kernel 5.4.0-216-generic、Go 1.24.13、VPP 24.10-release、GoVPP v0.13.0、Kubernetes v1.33.1、client-go v0.33.1、kind v0.29.0。VPP 使用 Goal 001 独立 runtime、TAP I/O 和单个 `vpp_main`，DPDK plugin 禁用。测试前 `go run ./cmd/goal002-inspect` 为 `interfaces=1 CNAT translations=0 sessions=0`。

VPP 入口节点在宿主独立实例；`g001-server` 同时是本地 backend 与隔离 namespace 路由器；`g004-remote` 是远端逻辑节点：

```text
g001-client 10.10.1.2
    -> TAP tap101 / VPP 10.10.1.1
    -> CNAT VIP 198.19.0.20:18080
    -> VPP tap102 10.10.2.1
    -> g001-server 10.10.2.2 (local backend, 10.10.3.1/30 router)
    -> g004uplink <veth> g004eth 10.10.3.2/30
    -> g004-remote lo 10.10.4.2/32 (remote backend)
```

GoVPP 写入 VPP `10.10.4.2/32 via 10.10.2.2 tap102`；`g001-server` namespace 中再经 `10.10.3.2` 到远端；远端默认路由经 `10.10.3.1` 回来。`net.ipv4.ip_forward=1` 只设置在 Goal 001 创建的 `g001-server` namespace，设置前记录原值；未改宿主 sysctl。实验 VIP 与 kube-proxy Service VIP 隔离。

## 可复现实验和 Stage A

kind 使用已有的固定 v1.33.1 node 镜像，`kind create cluster --name goal004 --image kindest/node:v1.33.1 --kubeconfig /tmp/goal004-kubeconfig --wait 2m` 返回 Ready。测试前采集 `/tmp/goal004-kind-before.txt`（netns/link/addr/route、Docker network/container、HugePages）。在干净的 Goal 001/VPP 环境下运行：

```bash
GOAL004_KUBECTL=/tmp/goal003-kubectl \
GOAL004_KUBECONFIG=/tmp/goal004-kubeconfig \
scripts/goal004/test-two-node.sh
```

最终复跑退出码 0。`vpp-goal004/echo-two-node` 的 EndpointSlice 含 local `10.10.2.2:18080` 与 remote `10.10.4.2:18080`。client 到远端直接 ping 3/3 成功；TCP/UDP VIP E2E 的客户端同时校验 payload、backend 身份与 reply peer=VIP：

```text
udp flows=20 payload=64 distribution={'10.10.2.2': 10, '10.10.4.2': 10}
tcp flows=20 payload=64 distribution={'10.10.2.2': 12, '10.10.4.2': 8}
Binary API dumps: interfaces=3 IPv4 routes=17 CNAT translations=2 sessions=80
Stats API: tap102 rx=131 tx=125 rx_errors=0 tx_errors=0
Stats API: tap101 rx=132 tx=124 rx_errors=0 tx_errors=0
```

VPP FIB 对远端 `/32` 显示 `API refs:1`、`oper-flags:resolved`、`10.10.2.2 tap102`，forwarding 为 `dpo-load-balance` 到 `ipv4 via 10.10.2.2 tap102`，包含实际 L2 rewrite 字节。`show ip neighbors` 显示 `10.10.2.2` 在 `tap102` 的动态 MAC；`show adj` 显示 `ipv4 via 10.10.2.2 tap102` complete adjacency。远端最终地址 `10.10.4.2` 不应出现在 VPP 的直接邻居表：VPP ARP 的是下一跳 `.2`，后续 `.2 -> .4` 由 Linux namespace 路由。

成功远端 UDP 的真实 trace：

```text
Packet 3: virtio-input -> ethernet-input -> ip4-input -> ip4-lookup
          -> ip4-cnat-tx
  session:[10.10.1.2;35001 -> 198.19.0.20;18080, UDP]
       => 10.10.1.2;35001 -> 10.10.4.2;18080
          -> ip4-load-balance -> ip4-rewrite -> tap102-output -> tap102-tx
Packet 4: 10.10.4.2;18080 -> 10.10.1.2;35001
          -> ip4-cnat-tx
       => 198.19.0.20;18080 -> 10.10.1.2;35001
          -> ip4-rewrite -> tap101 output
```

`ip4-cnat-tx` 完成 VIP/backend 正反向 session 改写；`ip4-load-balance` 选择 FIB/DPO；`ip4-rewrite` 使用邻接的 L2 rewrite；`tap102-tx` 输出到本地 router namespace，再经过 veth 到远端。trace 的后半段实际 node 以临时日志 `/tmp/goal004-final-run.log` 为准；仓库只记录关键片段。

## Stage B：故障、scale 和重启

断开 `g004eth` 后，已建立的远端 UDP session 新包真实超时。EndpointSlice 将远端标为 `ready=false`，VPP translation 中删除远端，10 条**新** UDP flow 全到 `.2`。此时 `show errors` 的 `null-node blackholed packets` 增至 2；它是故障窗口证据，未忽略。恢复 veth 时 Linux 自动移除了远端默认路由，因此脚本显式重建经 `10.10.3.1` 的 namespace 路由，先验证 L3/ARP，再把远端标回 `ready=true`；20 条新 flow 本地/远端各 10 条。

清掉受管 CNAT translation/session 与 API route 后重启 VPP；controller 在 VPP 停止时重新启动并记录 3 次 `VPP API socket file /run/vpp-goal001/api.sock does not exist`。重建同一 Goal 001 TAP 和 Goal 004 veth/FIB 后，controller 重新写入 TCP/UDP translation，UDP 20 条新 flow 为远端/本地 9/11，TCP 20 条为远端/本地 12/8。loopback metrics 输出 `reconcile_failures_total=3`、`reconcile_changes_total=2`，且 `last_success_unixtime` 晚于 `last_failure_unixtime`。这是真实的失败记录和恢复，不是仅检查进程存活。

排障记录：初次远端 ping 失败并收到 `10.10.2.2` ICMP redirect，原因是 server namespace 缺 `10.10.4.2/32 via 10.10.3.2`；补路由后 3/3 成功。第一次链路 down/up 后请求继续超时，检查 `ip -n g004-remote route` 发现默认路由被 Linux 删除；重建后恢复。初次 VPP 重启复验时，CNAT 先于实验 route 创建远端 backend 的 drop FIB entry；GoVPP route 程序现仅在确认该 drop entry 属于本实验 VIP/backend 时才添加 `/32`，对其他预存路由仍拒绝覆盖。24.10 的全局 CNAT purge 同时影响 translation，所以 cleanup 先确保无任何 translation、逐条确认 session 属于本实验，才 purge。

## Stage C：controller 观测和有界软件测量

`vpp-service-agent -metrics-listen 127.0.0.1:18084` 暴露 loopback `/metrics` 与 `/status`，含 reconcile attempts/failures/changes 和最近成功/失败时间。初始 metrics 为 attempts=6、failures=0、changes=2；VPP 重启恢复后 failures=3、changes=2，最近成功时间大于失败时间。此 HTTP 端点未对公网监听，且不采集宿主敏感配置。

测量条件：Intel Xeon E5-2698 v4，8 vCPU、1 socket/NUMA node；VPP `show threads` 仅 `vpp_main`，未配置额外 worker。I/O 为 Linux kernel/TAP/veth；Python 生成器在 g001-client 顺序发送新 flow，TCP/UDP 各 100 条，应用 payload 128 B，目标 offered load 为 200 flows/s，`--interval-us 5000`，无 TRex/pktgen/硬件 NIC。真实结果：

| 测量 | UDP | TCP |
| --- | --- | --- |
| 100 flow 耗时 | 0.495862 s | 0.496833 s |
| 本地/远端命中 | 51/49 | 46/54 |

测量前 Stats API：`tap101 rx=130 tx=123`，`tap102 rx=129 tx=124`；测量后：`tap101 rx=732 tx=723`，`tap102 rx=729 tx=726`，两侧 `rx_errors=tx_errors=0`。CNAT session 由 80 增至 480（每个新 TCP/UDP flow 对应正反向状态）。`show runtime`：`ip4-cnat-tx Calls=1360 Vectors=1443 Vectors/Call=1.06`、`ip4-load-balance 715/723/1.01`、`ip4-rewrite 1364/1447/1.06`；这是低流量下的观测，不作 VPP 吞吐或 line-rate 结论。测量前 `clear errors`，之后 `show errors` 为空。

## Cleanup 与验证

脚本删除测试 namespace、受管 CNAT translation/session、远端 `/32` API route、veth、三个实验 namespace/TAP，并复查宿主默认 route、管理接口地址和 HugePages。`goal004-purge` 输出 `purged 240 Goal 004 sessions`；最后 VPP `interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0`，只有 `local0`。远端 setup 执行两次，第二次报告已存在；cleanup 执行两次，第二次报告已清理。

`kind delete cluster --name goal004` 后，仅空 `kind` Docker bridge 留存；检查无 container 后删除该 bridge。测试前后相同命令采集 `/tmp/goal004-kind-before.txt` 与 `/tmp/goal004-kind-after.txt`，`diff -u` 退出码 0。宿主默认路由仍是 `default via 10.0.138.1 dev eth0 proto static`；原管理地址、原有 Docker 容器和 `vm.nr_hugepages=0` 未改变。

最终代码门槛：`gofmt -l`、`go test ./...`、`go vet ./...`、`bash -n scripts/goal001/*.sh scripts/goal002/*.sh scripts/goal003/*.sh scripts/goal004/*.sh`、`python3 -m py_compile scripts/goal002/service_traffic.py scripts/goal004/traffic.py`、`git diff --check` 均通过。

## 补充：VPP 双 worker 的 Service 功能复验（2026-10-14）

`scripts/goal004/test-multiworker.sh` 临时复制 Goal 001 startup config，只追加 `cpu { workers 2 }`；测试完删除临时配置并恢复原单 main thread VPP。`show threads` 在测试期间显示 `vpp_main`、`vpp_wk_0`、`vpp_wk_1`；`show interface rx-placement` 显示 `tap101 queue 0` 在 worker 0、`tap102 queue 0` 在 worker 1。两侧 `show runtime` 都有非零 `ip4-cnat-tx` 与 `ip4-rewrite` vectors。此验证只检查功能，不是性能测试。

首次直接以两个 worker 复跑 Goal 002 E2E 时，UDP 第一个应答的客户端 peer 是 `10.10.2.3:18080`，未被逆向改写成 VIP；即使把两个 TAP 都放在同一个 worker，未延迟的首次应答仍重现。脚本失败后清理了 translation、session、TAP 和 namespace，并恢复原 VPP。VPP 24.10 CNAT 源码中反向 client FIB 学习通过 `vl_api_rpc_call_main_thread` 发往 main thread；**首次应答过快与异步学习竞争是根据源码和现象作出的推断，尚未证明为唯一原因**。因此不能声称零延迟首次 UDP 应答在双 worker 下通过。

用固定 200 ms backend 应答延迟做受控复验，两个 worker 分别处理一个 TAP，完整 `scripts/goal002/test-service.sh` 退出 0。UDP 20 flow 分布 `.3:14/.2:6`，动态缩到 `.2` 后 10 条新 flow 均到 `.2`，恢复后 20 flow 分布 `.2:8/.3:12`；TCP 20 flow 分布 `.2:14/.3:6`，客户端 reply peer 均为 VIP。真实反向 trace 显示 `10.10.2.3;18080 -> 10.10.1.2;25000` 命中 `ip4-cnat-tx found session`，改写为 `198.18.0.10;18080 -> 10.10.1.2;25000`，随后 `ip4-rewrite -> tap101-output`。Stats API 显示 tap101 rx/tx=191/181、tap102=192/183，均无 RX/TX error；`show errors` 的 1 个 `null-node blackholed packets` 来自删除 Service 后的预期负例。删除 translation 后新 TCP/UDP flow 均失败，purge 后 `CNAT translations=0 sessions=0`。原单 main thread VPP、宿主默认 route、管理 IP 和 namespace 列表已恢复。

这一补充验证说明 VPP 24.10 在受控应答时延下，跨两个 worker 的 CNAT 正反向路径可运行；它也保留了首次快速应答漏改写的失败证据。该验证本身不能代替下述跨物理主机实验。

## 物理双节点环境核查（2026-10-14，尚未验收）

用户确认现有两台主机分别是本机 `hk-worker` 和 `38.55.146.97` 上的 control-plane。本机 hostname 确为 `hk-worker`，`wg0=10.253.0.2/30`；美国节点的 `wg0=10.253.0.1/30`。远端 `kubectl get nodes -o wide` 有这两个 Node 对象，但 `hk-worker` 为 `NotReady`，condition 是 `NodeStatusUnknown / Kubelet stopped posting node status`。最近一次 Node heartbeat 为 2026-08-30 09:20:22 UTC，Lease renew 为 09:20:46 UTC。Node 对象与本机指向同一节点身份；对象存在不代表本机 kubelet 当前仍在运行。

双方 WireGuard peer 均配置了对端地址，但最近一次 handshake 是 2026-10-08 14:19:49 UTC；`10.253.0.1` 与 `10.253.0.2` 双向 ICMP 均失败。远端 `tcpdump` 观察到本机发出的 UDP 握手及远端回包；本机 `tcpdump` 只观察到发出的握手，没有收到回包。远端发往本机 UDP 51820 的单独探测包也没有到达本机网卡。现有证据将故障定位到本机入站路径（可能是上游安全组/NAT），**不能仅凭这些观测断言具体云平台规则**。未关闭 firewall、修改管理 NIC/default route，也未改动两台主机的 WireGuard 配置。

因此，在这次核查时原逻辑节点实验仍成立，但尚无真实物理跨主机 Service packet E2E；Kubernetes 两节点 Ready 条件也未满足。下节通过临时 SSH TUN 补上了物理跨主机 packet E2E；它没有修复现有 WireGuard 或 Kubernetes worker。

## 独立双云主机 Service 补充实验（2026-10-14）

在现有 WireGuard 回包未到达本机的情况下，用 `scripts/goal004/test-physical-ssh-tun.sh` 临时在远端 loopback 启动仅监听 `127.0.0.1:2222`、允许 point-to-point TUN 的 sshd，经外层 SSH 本地转发建立内层 `ssh -w 3:3`。该连接通过 SSH/TCP 穿越两台**独立云服务器/VM**；它是功能实验，不代表 WireGuard 已恢复、原生 UDP tunnel、真实 NIC dataplane 性能或两个 Kubernetes Ready 节点。脚本使用外部 root-only askpass 和已核对的 known_hosts，不把密码、private key 或 kubeconfig 写入仓库。Kubernetes admin kubeconfig 仅临时存于 root-only `/run`，API 经另一个本地 SSH 端口转发，cleanup 删除它。

实验拓扑：

```text
g001-client 10.10.1.2 -> VPP tap101 -> CNAT 198.19.0.20:18080
  -> VPP tap102 -> g001-server 10.10.2.2 (local backend)
  -> g001-server tun3 10.254.0.2/30 == SSH/TCP == 远端 tun3 10.254.0.1/30
  -> 远端 host lo 10.10.4.2/32 (remote backend)
```

VPP 的 `10.10.4.2/32` 由 GoVPP 写为 `via 10.10.2.2 tap102`，实际 FIB 显示 `API refs:1`、`oper-flags:resolved`、`dpo-load-balance -> ipv4 via 10.10.2.2 tap102` 和 14-byte Ethernet rewrite；`show ip neighbors` 中 `10.10.2.2` 是 `tap102` 的动态下一跳。Linux 仅在实验 `g001-server` namespace 设置 `ip_forward=1` 与 `10.10.4.2/32 via 10.254.0.1`，远端仅在临时 `tun3` 添加到 client `/32` 的回程 route；两台宿主默认 route 不变。client 到远端 `10.10.4.2` ping 3/3 成功，TTL=62。远端 `tcpdump -i tun3` 捕获 `10.10.1.2:41000 -> 10.10.4.2:18080` UDP 请求和反向应答各 1 个包，证明 packet 到达另一台主机。

现有 control-plane 的真实 Kubernetes API 中创建隔离 `vpp-goal004-physical` Namespace、带 `198.19.0.20` test VIP 注解的 Service 和手工 EndpointSlice；本地、远端地址分别为 `.2.2`、`.4.2`。本机 controller 经 informer/desired-state/GoVPP 写入 TCP/UDP 两条 CNAT translation，VPP actual state 与 EndpointSlice 一致。**本地 backend 是实验 namespace，远端 backend 是另一台主机的 host loopback，均非 Kubernetes Pod；`hk-worker` Node 仍为 `NotReady`。**因此这项补充只证明真实主机间的 Service 数据路径和 Kubernetes 状态驱动，不能宣称 Kubernetes 两个 Ready worker 的 Pod dataplane 验收。

从干净环境完整运行脚本退出码 0；最终复跑的 TCP/UDP payload 为 64 B、每协议 20 条新 flow，客户端逐条验证 backend identity 与 reply peer=VIP：

```text
udp distribution={'10.10.4.2': 9, '10.10.2.2': 11}
tcp distribution={'10.10.4.2': 12, '10.10.2.2': 8}
Stats API: tap101 rx=141 tx=130 rx_errors=0 tx_errors=0
Stats API: tap102 rx=140 tx=132 rx_errors=0 tx_errors=0
CNAT translations=2 sessions=72
```

真实 trace 中远端 UDP 正向为 `virtio-input -> ethernet-input -> ip4-input -> ip4-lookup -> ip4-cnat-tx -> ip4-load-balance -> ip4-rewrite -> tap102-output -> tap102-tx`，session 把 `10.10.1.2:41000 -> VIP:18080` 改为 `10.10.1.2:41000 -> 10.10.4.2:18080`；反向 `ip4-cnat-tx` 的 `found session` 把 `10.10.4.2:18080 -> 10.10.1.2:41000` 改为 `VIP:18080 -> 10.10.1.2:41000`，然后 `ip4-rewrite -> tap101-output`。`show runtime`：`ip4-cnat-tx Calls/Vectors/Vectors per Call=1034/1183/1.14`、`ip4-rewrite=1170/1322/1.13`、`virtio-input=2630979230/1439/0.00`（大量空轮询）；`show threads` 只有 `vpp_main`，清空后的 `show errors` 只有表头。没有据此做性能结论。

实验将本地 `tun3` 置 down 后，已建立的远端 UDP flow 超时；EndpointSlice 远端 `ready=false` 后 10 条新 flow 全部转本地。恢复接口及回程 route、将 `ready=true` 后，20 条新 flow 本地/远端各 10 条；controller `/status` 显示 `Attempts=27, Failures=0, Changes=6`。手工测试中还重启过 controller，恢复后首次 `reconciled generation=1 services=2 changed=0`，VPP translation 未重复改写。链路 down 的丢包发生在 Linux/SSH TUN 一侧，清空后的 VPP error counter 未增长，不能把 timeout 冒充为 VPP drop counter。

首次将手工过程编成脚本时，在写入 GoVPP 远端 route 前就发出跨主机 ping，3/3 丢失；按实际依赖调整顺序后，从干净状态复跑退出码 0。脚本退出时删除 Kubernetes Namespace、controller、两个 backend server、CNAT session、API route、TAP/namespace、两端 `tun3`、远端实验 `/32` 地址/route、临时 sshd 与端口转发。最后 `Goal 004 physical cleanup status=0`；VPP `interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0`，本机 `ip netns list` 为空，远端无实验 `tun3`、地址、route 或 Namespace，两台主机默认 route 与管理地址均与采集前相同。现有 `wg0` 仍未恢复。

复现入口（参数值由执行环境提供，密码不写入命令参数或仓库）：

```bash
GOAL004_REMOTE_HOST=<authorized-host> \
GOAL004_SSH_ASKPASS=<root-only-askpass-program> \
GOAL004_KNOWN_HOSTS=<verified-known-hosts-file> \
GOAL004_KUBECTL=<kubectl-binary> \
scripts/goal004/test-physical-ssh-tun.sh
```

### Kubernetes worker 恢复的剩余条件

远端 control-plane 当前的 Cilium DaemonSet image 为 `quay.io/cilium/cilium:v1.20.1`。本机 hostname 与 Node 名均为 `hk-worker`，但当前系统为 Ubuntu 20.04、kernel `5.4.0-216-generic`，没有 `kubelet`/`kubeadm` 包、服务或 `/var/lib/kubelet`；Node 对象保留的最后上报状态是 Ubuntu 22.04、kernel `5.15.0-30-generic`、kubelet v1.36.4。现有证据不能确定系统变化的原因，不能将旧状态当成本机当前环境。当前仅安装 5.4 系列内核；APT 索引中的 `linux-generic-hwe-20.04` 候选为 5.15 系列，本机 `containerd` 1.7.24 正在运行。

按 [Cilium 1.20 官方系统要求](https://docs.cilium.io/en/stable/operations/system_requirements/)，容器部署要求 Linux kernel 至少 5.10（或明确列出的等价内核）。在用户授权恢复前，`apt-get -s install linux-generic-hwe-20.04` 仅模拟，报告 25 个新包、0 个升级、0 个删除，包含 5.15.0-139 内核；当时没有安装、重启或删除旧 Node。现有 SSH/TCP 实验通道只证明两台云主机的数据路径，未修复 WireGuard 入站或 kubelet 连通性。授权后的实际恢复进度见下一节。

### 本机 `hk-worker` 恢复进度（2026-10-14）

用户确认本机是 `hk-worker` 并授权修复当前环境。操作前将关键 host state（namespace/link/address/default route、相关 sysctl、VPP interface/thread、VPP 包版本、boot ID）保存到本机 root-only `/root/goal004-worker-recovery/before-host-state.txt`，权限 0600；未保存完整系统敏感配置。`apt-get install -y --no-install-recommends linux-generic-hwe-20.04` 实际新增 16 个包、升级 0 个、删除 0 个。重启后 boot ID 从 `cff3165f-c082-4c4a-b905-017385b2d030` 变为 `59b43ae0-a334-490e-aa74-df61a819d5d3`，`uname -r` 为 `5.15.0-139-generic`；旧 5.4 内核仍留在 `/boot`。`vpp` 与 `vpp-plugin-core` 仍为 `24.10-release`，没有升级。

按 [Kubernetes v1.36 官方安装步骤](https://v1-36.docs.kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) 添加专用 APT 源后，显式安装 `kubelet=kubeadm=kubectl=1.36.4-1.1`（加 `kubernetes-cni=1.9.1-1.1`），实际新增 4 个包、升级 0 个、删除 0 个；前三者设置 APT hold。`kubeadm version`、`kubelet --version`、`kubectl version --client` 均显示 v1.36.4，与控制平面一致。`containerd` 的 CRI plugin 为 `ok`，`swapon --show` 为空；5.15 内核配置显示 BPF、cgroup BPF、BTF、VXLAN/Geneve 可用。尚未执行 `kubeadm join`，本机 kubelet service 因没有集群配置而 inactive；不能据此宣称 Node Ready。

重启使手工启动的 Goal 001 VPP 停止；运行 `scripts/goal001/start-vpp.sh` 后 CLI/API socket 正常，GoVPP `goal002-inspect` 的 message/CRC 兼容，实际状态为 interfaces=1、IPv4 routes=5、CNAT translations/sessions=0。重新 setup TAP、配置 L3 后，首次 ICMP 3 发 2 收（首包 ARP/glean），邻居解析后再次 3 发 3 收；UDP `goal001-udp`/`goal001-ack` 双向成功。成功 trace 经过 `virtio-input -> ethernet-input -> ip4-input -> ip4-lookup -> ip4-rewrite -> tap102-output -> tap102-tx`。cleanup 后 namespace 为空、VPP 仅 `local0`，GoVPP 再次显示 interfaces=1、routes=5、CNAT=0/0；本机默认路由仍是 `default via 10.0.138.1 dev eth0`，管理地址仍为 `10.0.138.51/24`。这仅重验 Goal 001 基线，未冒充双节点 Pod E2E。

剩余阻塞是两节点间的稳定可信连接：重启后 `wg0` 仍为 `10.253.0.2/30`，但 WireGuard 收包为 0、最近握手为空，`ping 10.253.0.1` 为 0/2；本机 INPUT policy 为 ACCEPT。美国节点用 UDP 向本机公网 `38.76.199.157:51820` 发固定探测包，远端 `tcpdump -i eth0` 看到发往该地址的 UDP 包，本机同时在 `eth0` 抓取来自 `38.55.146.97` 的该端口流量，结果 0 包。现有证据定位到两端主机之间的入站路径，但不能断言是哪一条云平台规则。美国节点的 Kubernetes `cluster-info` 和 kubelet kubeconfig 使用 `https://10.0.72.27:6443`；本机虽能连通其公网 `38.55.146.97:6443` TCP，但 API 证书 SAN 仅含私网 `10.0.72.27` 等地址，不含公网 IP。

原本本机 WireGuard peer `AllowedIPs` 只有 `10.253.0.1/32`，到控制平面私网 API `10.0.72.27` 的路由走宿主默认网关。先将相关 `wg0.conf` 以 0600 权限备份在本机 root-only 恢复目录，再只把该 peer 的 `AllowedIPs` 扩为 `10.253.0.1/32, 10.0.72.27/32`；`wg-quick@wg0` 重启后 `ip route get 10.0.72.27` 显示 `dev wg0 src 10.253.0.2`，默认 route 和 eth0 管理地址不变，现有公网 SSH 仍可达。隧道握手依然为空，故尚不能访问私网 API。未改动云平台入站规则或集群 Node/Pod 对象。`hk-worker` 仍 NotReady；现有 Pod 列表还含 `netlab/netlab-b`，因此不会为图省事删除旧 Node。恢复网络后再安全执行入群和真实 Pod E2E。
