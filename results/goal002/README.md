# Goal 002 运行证据

状态：进行中；本页覆盖 Stage A 的版本/schema 核对与 Stage B 的 GoVPP FIB/Stats 实测。CNAT VIP/多 backend/会话/动态变更尚未验证，Goal 002 未完成。Stage A 提交为 `6c494aa`。

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
