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

这一补充验证说明 VPP 24.10 在受控应答时延下，跨两个 worker 的 CNAT 正反向路径可运行；它也保留了首次快速应答漏改写的失败证据。实际跨物理主机测试尚未完成，不能用本节或上面的逻辑节点实验代替。
