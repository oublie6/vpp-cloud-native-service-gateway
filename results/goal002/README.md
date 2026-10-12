# Goal 002 运行证据

状态：Goal 002 Stage A～C 已实现并通过本机工程复验；ChatGPT 学习/工程验收待确认。Stage A 提交为 `6c494aa`，Stage B 提交为 `7d5832d`；Stage C 代码与证据在后续 focused commit 中。

## 2026-10-12：同步与环境

- `git status --short` 为空，分支 `main`；`git fetch origin` 成功，`git pull --ff-only origin main` 将 `7f40bb5` 快进至 `89bed53`。
- Ubuntu 20.04 focal；kernel `5.4.0-216-generic`；Go `go1.24.13`；已安装 VPP `24.10-release`、GoVPP `v0.13.0`。没有升级 VPP。
- 初始 `show plugins` 为空；机器只有 `vpp` 和 `libvppinfra` 包，没有 CNAT plugin/API JSON。`vpp-plugin-core` 的 APT candidate 为 `24.10-release`。

## 安装同版 core plugin 前后 host state

安装前：`apt-get -s install vpp-plugin-core=24.10-release` 输出 **0 upgraded, 1 newly installed**；`vm.nr_hugepages=0`，`/etc/sysctl.d/80-vpp.conf` 的持久值也是 0；宿主默认路由 `default via 10.0.138.1 dev eth0 proto static`；`eth0` 为 `UP`、`10.0.138.51/24`；`ip netns list` 为空；独立 VPP 仅有 `local0`。未读取或保存其他宿主敏感配置。

执行 `apt-get install -y vpp-plugin-core=24.10-release` 成功，APT 确认 **0 upgraded, 1 newly installed**。安装后 `vpp`、`libvppinfra`、`vpp-plugin-core` 都为 `24.10-release`；`vm.nr_hugepages=0`、默认路由与 `eth0` 状态及地址不变；namespace 仍为空，系统 `vpp.service` 为 inactive。重启 Goal 001 独立 VPP 实例后，`show plugins` 显示 `cnat_plugin.so 24.10-release`；`/usr/share/vpp/api/plugins/cnat.api.json` 与 `/usr/lib/x86_64-linux-gnu/vpp_plugins/cnat_plugin.so` 均存在。DPDK plugin 在项目 startup 配置中仍禁用。

## API/schema 核对

GoVPP v0.13.0 内置 `binapi/cnat/cnat.ba.go` 的生成头标注 VPP `25.10-release`，因此逐项与实际安装的 24.10 API JSON 比对。以下所需 message CRC 相同：

| API | 24.10 与 GoVPP CRC |
| --- | --- |
| `cnat_translation_update` / reply | `f8d40bc5` / `e2fc8294` |
| `cnat_translation_del` / reply | `3a91bde5` / `e8d4e804` |
| `cnat_translation_dump` / details | `51077d14` / `1a5140b7` |
| `cnat_session_dump` / details | `51077d14` / `7e5017c7` |
| `ip_route_add_del` / reply | `b8ecfe0d` / `1992deab` |
| `ip_route_dump` / details | `b9d2e09e` / `bda8f315` |
| `sw_interface_add_del_address` / reply | `5463d73b` / `e8d4e804` |
| `sw_interface_set_flags` / reply | `f5aec1b8` / `e8d4e804` |
| `sw_interface_dump` / details | `aa610c27` / `6c221fc7` |

`cmd/goal002-inspect` 进一步通过当前实例的 Binary API channel `CheckCompatiblity` 核对全部上述消息，并实际调用 interface、IPv4 route、CNAT translation/session dump；Stats API 经独立 `/run/vpp-goal001/stats.sock` 读取 interface counters。真实输出：

```text
$ go run ./cmd/goal002-inspect
Binary API message/CRC: interface, FIB, CNAT compatible
Binary API dumps: interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0
Stats API: local0 index=0 rx=0 tx=0 rx_errors=0 tx_errors=0
```

错误 socket 的非零退出也已验证：

```text
$ go run ./cmd/goal002-inspect -api-socket /run/vpp-goal001/missing.sock
连接 Binary API /run/vpp-goal001/missing.sock: VPP API socket file /run/vpp-goal001/missing.sock does not exist
exit status 1
```

`go mod tidy` 只补入 GoVPP Stats adapter 所需的间接依赖 `github.com/ftrvxmtrx/fd v0.0.0-20150925145434-c6d800382fff`，GoVPP 和 VPP 版本均未改变。

## 机制依据与当前限制

- [FD.io VPP 24.10 Cloud NAT 官方文档](https://docs.fd.io/vpp/24.10/developer/plugins/cnat.html)：translation 可含多个 backend，按 flow hash 选择；session 保存正向及逆向 rewrite。文档也明确 VIP translation 的 3-tuple 匹配与统计/会话管理限制。
- 当前机器的 `/usr/share/vpp/api/plugins/cnat.api.json`、`/usr/share/vpp/api/core/ip.api.json`、`interface.api.json` 是实际安装版 schema；GoVPP `v0.13.0` 生成文件的 CRC 与运行时 `CheckCompatiblity` 是本次具体 message 的兼容证据。兼容结论仅覆盖所列消息，不外推到整个 25.10 binding 集。
- 尚无 CNAT translation、session 或 Service packet E2E 证据，不能把本阶段 read-only probe 写成 Service 功能已完成。

## Stage B：GoVPP 接口地址、FIB 与 Stats（2026-10-12）

`cmd/goal002-fib` 使用 VPP Binary API 的 `SwInterfaceDump` 按接口名查找 `tap101`/`tap102` 当前 index，用 `IPAddressDump` 判断地址是否已存在，再调用 `SwInterfaceAddDelAddress` 和 `SwInterfaceSetFlags`。实验路由 `198.18.0.3/32 via 10.10.2.2 tap102` 由 `IPRouteAddDel` 写入/删除。Linux 侧仅在 Goal 001 namespace 内设置 default gateway 和 server `lo` 上的 `198.18.0.3/32`；宿主默认路由不参与实验。

复现入口为 `scripts/goal002/test-fib.sh`。脚本要求干净的 Goal 001 拓扑、root 和 VPP 实例；创建前检查 ownership marker/namespace/TAP；退出时删除 API 地址/路由及 Goal 001 TAP/namespace，并比对宿主 default route、管理接口状态及实验资源消失。脚本运行两次均成功。第二次关键输出：

```text
setup tap101 10.10.1.1/24
setup tap102 10.10.2.1/24
setup tap101 10.10.1.1/24
setup tap102 10.10.2.1/24
Binary API dumps: interfaces=3 IPv4 routes=13 CNAT translations=0 sessions=0
Stats API: tap101 index=1 rx=2 tx=0 rx_errors=0 tx_errors=0
Stats API: tap102 index=2 rx=2 tx=0 rx_errors=0 tx_errors=0
route-add 198.18.0.3/32 via 10.10.2.2 tap102
route-add 198.18.0.3/32 via 10.10.2.2 tap102
PING 198.18.0.3: 3 packets transmitted, 3 received, 0% packet loss
Stats API: tap101 index=1 rx=10 tx=4 rx_errors=0 tx_errors=0
Stats API: tap102 index=2 rx=10 tx=4 rx_errors=0 tx_errors=0
route-del 198.18.0.3/32 via 10.10.2.2 tap102
route-del 198.18.0.3/32 via 10.10.2.2 tap102
PING 198.18.0.3: 2 packets transmitted, 0 received, 100% packet loss
Goal 002 FIB add/delete 与 packet 验证通过
Goal 001 TAP/namespace 已清理；原始状态记录：/run/vpp-goal001/topology-before.txt
```

路由存在时，`show ip fib 198.18.0.3/32` 的 `API refs:1`、`path 10.10.2.2 tap102`、`dpo-load-balance -> ipv4 via 10.10.2.2 tap102` 和完整 L2 rewrite 与 3/3 ping 相互印证。删除后同一查询回落到 `0.0.0.0/0` 的 drop DPO，2 次 ping 均无回复。这证明 GoVPP 写入/删除改变了 VPP actual FIB。

Stats API 两侧 TAP 的 RX 从 2 到 10、TX 从 0 到 4，RX/TX error 均为 0；累计差值包含 ARP/自动流量，不把全部 8 个 RX 当作 3 个 ICMP packet。两轮中 TAP index 与 MAC 均可能变化，命令按接口名查询 index。

cleanup 后 `ip netns list` 为空、VPP `show interface` 仅有 `local0`；宿主 `default via 10.0.138.1 dev eth0 proto static` 与 `eth0 UP 10.0.138.51/24` 未变。`git diff --check`、`go test ./...`、`go vet ./...`、`bash -n scripts/goal002/*.sh` 全部通过。

## Stage C：CNAT 多 backend Service（2026-10-12）

复用 Goal 001 的两个 TAP，不增加宿主接口。`g001-client=10.10.1.2/24` 经 VPP `tap101=10.10.1.1/24` 访问独立测试 VIP `198.18.0.10:18080`；两个 backend 是同一个隔离 `g001-server` namespace 内各自绑定 `10.10.2.2:18080`、`10.10.2.3:18080` 的 TCP/UDP listener，经 VPP `tap102=10.10.2.1/24` 到达。两端 Linux default route 仅在 namespace 内设置。Goal 004 再验证跨节点 backend；本节只证明两个不同 IP/backend listener 的选择与改写。

`cmd/goal002-service` 通过 GoVPP `CnatTranslationUpdate`/`Del`/dump 和 session dump 配置、更新、删除 TCP/UDP translation；`scripts/goal002/service_traffic.py` 逐 flow 核对返回 payload、backend IP 与客户端看到的 VIP 源地址。`scripts/goal002/test-service.sh` 从干净拓扑自动 setup、生成流量、采集 trace/counter、删除和 cleanup；两次从干净拓扑运行成功。最后一次实测摘要：

```text
applied udp 198.18.0.10:18080 id=1 backends=2 lb=maglev
applied tcp 198.18.0.10:18080 id=0 backends=2 lb=maglev
udp distribution {'10.10.2.3': 14, '10.10.2.2': 6}  # 20 flow，每 flow 连续请求 2 次，同 flow backend 不变
UDP 正反向 session 数：40；旧 .3 flow 源端口：20000
applied udp 198.18.0.10:18080 id=1 backends=1 lb=maglev
udp 20000 -> 10.10.2.3  # 旧 session 保持 .3
udp distribution {'10.10.2.2': 10}  # 新 flow 只走保留的 .2
applied udp 198.18.0.10:18080 id=1 backends=2 lb=maglev
udp distribution {'10.10.2.2': 8, '10.10.2.3': 12}  # 新 flow 再次分到两个 backend
tcp distribution {'10.10.2.2': 14, '10.10.2.3': 6}  # 20 条 TCP 连接
```

客户端逐条检查到 UDP/TCP 应答的 peer 都为 `('198.18.0.10', 18080)`，backend 应答 payload 中的 IP 分别是 `.2` 或 `.3`；这同时证明正向 VIP→backend 与反向 backend→VIP 改写。20 flow 的分布只是本次功能样本，不是负载均衡均匀性或性能结论。已有 UDP session 的 `.3` backend 即使从 translation path 列表删除，短时间内仍能完成请求；新源端口均走 `.2`。手工验证中该旧 session 稍后过期，新请求超时，因此不声称它无限期存活。

VPP `show ip fib 198.18.0.10/32` 实际显示 `cnat refs:1`、`entry-flags:exclusive`、`cnat-client:[198.18.0.10]`，VIP 未绑到接口。`show cnat translation` 显示两个 backend 的 path 和 `lb:maglev`。GoVPP session dump 在初始 20 UDP flow 后为 40 条正反向 session；所有 TCP/UDP 流量后 `cmd/goal002-inspect` 读到 2 条 translation、148 条 session。24.10 官方源码 `cnat_api.c` 表明 `CnatSessionPurge` **同时清除所有 translation**；项目的 purge 命令先拒绝存在任何 translation 或非本实验 session，避免误删。先删除两条 translation 后，purge 了本实验 148 条 session，下一次 API dump 为 `translations=0 sessions=0`。随后新 UDP 与 TCP flow 均失败，符合 Service 删除后的预期。

从清理前的真实 `show trace`，请求与回包的首条路径是：

```text
请求：virtio-input -> ethernet-input -> ip4-input -> ip4-lookup
      -> ip4-cnat-tx (created session, 10.10.1.2:25000 -> 198.18.0.10:18080
          => 10.10.1.2:25000 -> 10.10.2.3:18080)
      -> ip4-load-balance -> ip4-rewrite -> tap102-output -> tap102-tx
回包：virtio-input -> ethernet-input -> ip4-input -> ip4-lookup
      -> ip4-cnat-tx (found session, 10.10.2.3:18080 -> 10.10.1.2:25000
          => 198.18.0.10:18080 -> 10.10.1.2:25000)
      -> ip4-rewrite -> tap101-output -> tap101-tx
```

这里与 Goal 001 普通 L3 trace 不同：CNAT 请求在 `ip4-cnat-tx` 创建 session 后显式进入 `ip4-load-balance`，回包则命中已有 reverse session。`show runtime` 的累计 Calls/Vectors/Vectors/Call：`ip4-cnat-tx 1263/1325/1.05`、`ip4-load-balance 654/662/1.01`、`ip4-rewrite 1282/1341/1.05`、`virtio-input 563684407/1473/0.00`（包含空轮询及此前实验，不能用于性能结论）。Stats API 的 `tap101 rx=183 tx=178`、`tap102 rx=184 tx=179`，两侧 RX/TX error 都为 0。trace 前 `clear errors` 后仍观察到 `null-node blackholed packets=4`；实验 TAP 的自动背景流量及未启用 IPv6 是可能来源，但未逐包归因，不能将这 4 次计数归为 CNAT 请求失败；成功的 TCP/UDP E2E 与双向 trace 是独立证据。

测试了受限输入和失败路径：`-backends 10.0.138.51` 返回“backend 不在 Goal 002 隔离地址范围”并退出 1；错误 API socket 退出 1；仍有 translation 时全局 purge 被拒绝。脚本最终重复删除 translation 与 purge 均成功，Goal 001 namespace/TAP/ownership marker 消失，VPP 只剩 `local0`，宿主默认路由、管理接口和 HugePages（0）未变化。证据属于 Linux namespace/TAP/VPP software dataplane，无吞吐性能主张。

匹配版本的一手依据：[VPP 24.10 CNAT 文档](https://docs.fd.io/vpp/24.10/developer/plugins/cnat.html)、[v24.10 `cnat_api.c`](https://github.com/FDio/vpp/blob/v24.10/src/plugins/cnat/cnat_api.c)、[v24.10 `cnat_translation.c`](https://github.com/FDio/vpp/blob/v24.10/src/plugins/cnat/cnat_translation.c)、[v24.10 `cnat_node_vip.c`](https://github.com/FDio/vpp/blob/v24.10/src/plugins/cnat/cnat_node_vip.c)、[v24.10 `cnat_src_policy.c`](https://github.com/FDio/vpp/blob/v24.10/src/plugins/cnat/cnat_src_policy.c)。实际运行行为和本机 24.10 API JSON 优先于这些材料的泛化描述。
