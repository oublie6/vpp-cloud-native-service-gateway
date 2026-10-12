# Goal 002 运行证据

状态：进行中；本页目前只覆盖 Stage A 的版本、schema 与 read-only API probe。FIB 写入、CNAT VIP/多 backend/会话/动态变更尚未验证，Goal 002 未完成。

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
- 尚无 CNAT translation、session 或 packet E2E 证据，不能把本阶段 read-only probe 写成 Service 功能已完成。
