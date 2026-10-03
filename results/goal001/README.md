# Goal 001 / Stage 1 运行证据

采集日期：2026-09-30 UTC。命令在 Ubuntu 20.04 主机原生执行；未使用容器。以下输出做了空白压缩，未改变命令结果。

## Git 与安装前环境

```text
$ git branch --show-current
main
$ git rev-parse HEAD
52b3b0c49080bed1b00aaadb7e07cc5669d1c36f
$ git status --short
(空；安装前工作区干净)
$ uname -r; uname -m
5.4.0-216-generic
x86_64
$ . /etc/os-release; printf '%s %s (%s)\n' "$NAME" "$VERSION_ID" "$VERSION_CODENAME"
Ubuntu 20.04 (focal)
$ go version
go version go1.13.8 linux/amd64
$ command -v vpp; dpkg-query -W 'vpp*'
(安装前均无 VPP)
```

同步命令 `git fetch origin` 与 `git pull --ff-only origin main` 成功，后者返回 `Already up to date.`。

## 版本选择与主机安装

- FD.io release APT 仓库的 focal 列表：`apt-cache madison vpp` 最高为 `24.10-release`，其后是 `24.06-release`、`24.02-release`；无 `26.06-release`。官方 26.06 包面向 jammy/noble。故安装 focal 可获得的最新稳定 `vpp=24.10-release`、`libvppinfra=24.10-release`，没有切到 master/RC。
- GoVPP 固定 `go.fd.io/govpp v0.13.0`。该模块声明 `go 1.24.0`，主机 Go 已升级到 `go1.24.13`（官方归档 SHA256 `1fc94b57134d51669c72173ad5d49fd62afb0f1db9bf3f798fd98ee423f8d730`）。
- `dpkg-query -W vpp libvppinfra`：两者均为 `24.10-release`。`go version`：`go1.24.13 linux/amd64`。
- 安装包的 postinst 自动启动默认 VPP，并设置 `vm.nr_hugepages=1024`。发现后执行 `systemctl stop vpp`、`systemctl disable vpp`，把 `/etc/sysctl.d/80-vpp.conf` 的该值及运行值恢复到 0。后续只用项目独立配置，`sysctl vm.nr_hugepages` 验证为 0。原安装前 HugePages 值未采集，故只能证明运行时和当前持久配置均为 0。
- VPP 24.10 本机 API JSON：`/usr/share/vpp/api/core/vpe.api.json`。其中 `show_version` CRC `0x51077d14`、`show_version_reply` CRC `0xc919bde1`；GoVPP v0.13.0 的 `ShowVersionReply` CRC 为 `c919bde1`。实际调用成功是本 Stage 的 schema 兼容性证据；不推断其他 API 兼容。

参考：

- FD.io 安装文档：https://s3-docs.fd.io/vpp/26.06/gettingstarted/installing/index.html
- FD.io focal release 列表：https://packagecloud.io/app/fdio/release/search?dist=ubuntu%2Ffocal
- GoVPP 仓库：https://github.com/FDio/govpp/tree/v0.13.0
- VPP 配置参考：https://docs.fd.io/vpp/24.10/gettingstarted/progressivevpp/runningvpp.html

## VPP 与 Binary API 实测

```text
$ scripts/goal001/start-vpp.sh
VPP 已启动: CLI=/run/vpp-goal001/cli.sock Binary API=/run/vpp-goal001/api.sock
$ ps -fp "$(< /run/vpp-goal001/vpp.pid)"
root 1660421 ... vpp -c /root/vpp-cloud-native-service-gateway/deploy/vpp/startup-goal001.conf
$ stat -c '%F %n' /run/vpp-goal001/cli.sock /run/vpp-goal001/api.sock
socket /run/vpp-goal001/cli.sock
socket /run/vpp-goal001/api.sock
$ vppctl -s /run/vpp-goal001/cli.sock show version
vpp v24.10-release built by root on e8a9406d5d7d at 2024-10-30T13:32:02
$ vppctl -s /run/vpp-goal001/cli.sock show interface
Name    Idx  State  MTU ...
local0  0    down   0/0/0/0
$ vppctl -s /run/vpp-goal001/cli.sock show runtime
Time 13.2, 10 sec internal node vector rate 0.00 loops/sec 163124.63
vector rates in 0.0000e0, out 0.0000e0, drop 0.0000e0, punt 0.0000e0
api-rx-from-ring ...
unix-epoll-input polling ...
$ vppctl -s /run/vpp-goal001/cli.sock show errors
Count  Node  Reason  Severity
(无 error 行)
$ go run ./cmd/vpp-probe
API socket: /run/vpp-goal001/api.sock
VPP program: vpe
VPP version: 24.10-release
Build date: 2024-10-30T13:32:02
Build directory: /w/workspace/vpp-merge-2410-ubuntu2004-x86_64
GoVPP version: v0.13.0
$ go run ./cmd/vpp-probe -api-socket /run/vpp-goal001/missing.sock
API socket: /run/vpp-goal001/missing.sock
连接 VPP Binary API socket "/run/vpp-goal001/missing.sock": VPP API socket file /run/vpp-goal001/missing.sock does not exist
exit status 1
实际命令 exit code: 1
```

## 检查与清理

```text
$ git diff --check
(无输出，exit 0)
$ go test ./...
? github.com/oublie6/vpp-cloud-native-service-gateway/cmd/vpp-probe [no test files]
$ go vet ./...
(无输出，exit 0)
$ bash -n scripts/goal001/*.sh
(无输出，exit 0)
$ scripts/goal001/stop-vpp.sh
Goal 001 VPP 已停止
$ test ! -e /run/vpp-goal001/api.sock && test ! -e /run/vpp-goal001/cli.sock && test ! -e /run/vpp-goal001/vpp.pid
(exit 0；两个 socket 和 pidfile 已清理)
```

生命周期：默认系统 `vpp.service` 已禁用；Stage 1 实例只能由 `start-vpp.sh` 启动、`stop-vpp.sh` 停止。`/run/vpp-goal001/vpp.log` 留在主机供故障排查，不提交到仓库。

## Stage 2：软件 TAP 拓扑（2026-10-03 UTC）

实际环境再次核对：Ubuntu 20.04、kernel `5.4.0-216-generic`、Go `1.24.13`、VPP `24.10-release`、GoVPP `v0.13.0`。`/run/vpp-goal001/cli.sock` 与 `api.sock` 由 Goal 001 独立实例创建，系统 `vpp.service` 为 inactive，DPDK plugin 禁用。实际 CLI 无 `create host-interface`，`help create tap` 提供 `host-ns` 和 `host-if-name`，故选择 VPP TAP/virtio 软件接口。

```text
g001-client [g001tapc, 10.10.1.2/24]
          ↕ Linux TAP fd / VPP virtio (tap101, sw_if_index 1)
        VPP
          ↕ VPP virtio / Linux TAP fd (tap102, sw_if_index 2)
g001-server [g001taps, 10.10.2.2/24]
```

TAP Linux 端直接在 namespace 内；宿主根 namespace 不获得实验 IP。Stage 2 暂不设置 VPP L3 地址，故 VPP sw interface 为 admin down；hardware link 显示 up。`scripts/goal001/topology-common.sh` 集中定义名称和 IP，`setup-topology.sh` 在创建前把相关 host/VPP 状态写到 `/run/vpp-goal001/topology-before.txt`，`cleanup-topology.sh` 凭 ownership marker 删除所建 TAP 和 namespace。该运行时记录不提交到 Git。

创建前状态摘要（原始记录的 `ip netns list` 为空）：

```text
ip -br link: eth0 UP d8:88:ef:00:01:c6; wg0 UNKNOWN; docker0 DOWN; br-47f313e555f1 UP; 另有两条 Docker veth
ip -br addr: eth0 10.0.138.51/24; wg0 10.253.0.2/30; docker0 172.17.0.1/16; br-47f313e555f1 172.18.0.1/16
ip -4 route: default via 10.0.138.1 dev eth0 proto static; 其余为上述接口的 connected routes
VPP show interface: local0 idx 0 down
```

本 Stage 没有修改 sysctl。创建后真实检查：

```text
$ scripts/goal001/setup-topology.sh
Goal 001 TAP 拓扑已创建：g001-client/g001tapc -> VPP -> g001-server/g001taps
$ scripts/goal001/setup-topology.sh
Goal 001 拓扑已存在
$ ip netns list
g001-server
g001-client
$ ip -n g001-client -br addr; ip -n g001-server -br addr
g001tapc UNKNOWN 10.10.1.2/24 ...
g001taps UNKNOWN 10.10.2.2/24 ...
$ vppctl -s /run/vpp-goal001/cli.sock show interface
local0  0 down
tap101  1 down 9000/0/0/0
tap102  2 down 9000/0/0/0
$ vppctl -s /run/vpp-goal001/cli.sock show hardware-interfaces
tap101 1 up tap101; VIRTIO interface; RX queue 0 on main (polling); TX queue 0
tap102 2 up tap102; VIRTIO interface; RX queue 0 on main (polling); TX queue 0
```

首次 cleanup 用了错误的 `delete tap id 101`，CLI 报 `unknown input`；按本机 `help delete tap` 改为 `delete tap tap101` 后成功。失败发生在删除任何对象之前，未造成 host 状态变化。清理证据：

```text
$ scripts/goal001/cleanup-topology.sh
Goal 001 TAP/namespace 已清理；原始状态记录：/run/vpp-goal001/topology-before.txt
$ scripts/goal001/cleanup-topology.sh
Goal 001 拓扑不存在；未删除任何对象
$ ip netns list
(空)
$ vppctl -s /run/vpp-goal001/cli.sock show interface
local0 0 down
$ ip -4 route show default
default via 10.0.138.1 dev eth0 proto static
$ ip -br link show eth0; ip -br addr show eth0
eth0 UP d8:88:ef:00:01:c6 ...
eth0 UP 10.0.138.51/24 ...
```

## Stage 3：两接口 IPv4 转发（2026-10-03 UTC）

在 Stage 2 的 TAP 拓扑上执行 `scripts/goal001/setup-topology.sh` 与 `configure-forwarding.sh`。后者将 `tap101=10.10.1.1/24`、`tap102=10.10.2.1/24` 设为 up，并仅在两个 namespace 内配置 default gateway；重复执行成功。宿主 `default via 10.0.138.1 dev eth0` 不变。

ARP/业务流量前的真实状态：`show interface addr` 显示上述两侧 L3 地址；namespace route 分别为 `default via 10.10.1.1 dev g001tapc` 和 `default via 10.10.2.1 dev g001taps`。`show ip neighbors` 为空，`show adj` 仅有两侧的 `ipv4-glean`；`show ip fib` 的 `10.10.1.0/24`、`10.10.2.0/24` 均经单 bucket `dpo-load-balance` 指向对应 `ipv4-glean`。自动 IPv6 multicast 已使两个 TAP 各有约 7 个 RX/drop，`show errors` 中有 14 个 `null-node blackholed packets`，并非本次 IPv4 转发的基准零值。

首次 `ping -c 3 10.10.2.2` 发出 3 个、收到 2 个（首包触发 ARP/glean 后丢失）；随后邻居已解析，`scripts/goal001/test-forwarding.sh` 的 ICMP 为 `3 transmitted, 3 received, 0% packet loss`。UDP 用 Python socket 从 client 发 `goal001-udp` 到 server `10.10.2.2:19001`，server 回 `goal001-ack`，client 收到来自 `10.10.2.2:19001` 的确认；双向应用层内容均核对成功。

```text
$ vppctl -s /run/vpp-goal001/cli.sock show ip fib 10.10.2.0/24
entry-flags:connected,attached; cfg-flags:glean; tap102
forwarding: dpo-load-balance index:12 -> ipv4-glean tap102
$ vppctl -s /run/vpp-goal001/cli.sock show ip fib 10.10.2.2/32
entry-flags:attached; oper-flags:resolved; 10.10.2.2 tap102
forwarding: dpo-load-balance index:17 -> ipv4 via 10.10.2.2 tap102
rewrite: 02febf0f391c02fe15d833b30800
$ vppctl -s /run/vpp-goal001/cli.sock show ip neighbors
10.10.1.2 D 02:fe:01:62:9d:cf tap101
10.10.2.2 D 02:fe:bf:0f:39:1c tap102
$ vppctl -s /run/vpp-goal001/cli.sock show adj
[@4] ipv4 via 10.10.1.2 tap101 ... 02fe01629dcf02fe1385c84f0800
[@5] ipv4 via 10.10.2.2 tap102 ... 02febf0f391c02fe15d833b30800
```

`02febf0f391c` 是 server Linux TAP MAC，`02fe15d833b3` 是 VPP tap102 MAC，`0800` 是 IPv4 EtherType；这段 14-byte rewrite 与完整 adjacency 一致。子网的 glean adjacency 仍保留供新目的邻居解析，具体 host 的 `/32` FIB 则解析为 complete adjacency。这里观察到的是未解析（无 neighbor、仅 glean）到已解析（neighbor、host FIB、完整 rewrite）的转换；没有直接观察到持久的 incomplete adjacency 条目，故不声称采集到了它。

接口计数从初次流量前的 `tap101 rx 7, tx 0`、`tap102 rx 7, tx 0` 增至 ICMP/UDP 后的 `tap101 rx 18, tx 8`、`tap102 rx 17, tx 8`。`show errors` 后值包括 `null-node blackholed packets 18`、`arp-reply ARP replies sent 3 (info)`、`ip4-glean ARP requests sent 1 (info)`；空闲期间的 IPv6 multicast/drop 与首包 ARP 也计入，因此不把全部计数解释为成功 IPv4 packet。删除 TAP/namespace 会删除本 Stage 的 VPP 地址、邻居与 namespace route；Stage 4 继续复用当前拓扑，最终清理时验证。

## Stage 4：真实 graph 与 packet trace（2026-10-03 UTC）

在 Stage 3 已解析的邻居状态上，`show hardware-interfaces` 确认 TAP 是 VIRTIO；`show runtime` 显示 `virtio-input` 为 polling，`show node virtio-input` 确认其 `next-index 4 -> ethernet-input`。本机没有 `tap-input` node，故 trace 使用真实 input node。`scripts/goal001/capture-trace.sh` 清空 trace/error，执行 `trace add virtio-input 4`，发送 1 个 client -> server ping，再输出 trace、errors、runtime、threads。ping 为 `1 transmitted, 1 received`。

请求 packet 的真实 trace 摘要（未补造中间 node）：

```text
virtio-input       hw_if_index 2, next-index 4, vring 0, len 98, num_buffers 1
ethernet-input     sw_if_index 2, 02:fe:01:62:9d:cf -> 02:fe:13:85:c8:4f
ip4-input          ICMP 10.10.1.2 -> 10.10.2.2, ttl 64, length 84
ip4-lookup         fib 0, dpo-idx 5
ip4-rewrite        tx_sw_if_index 1, dpo-idx 5, ipv4 via 10.10.2.2 tap102
                   rewrite 02febf0f391c02fe15d833b30800
tap102-output      02:fe:15:d8:33:b3 -> 02:fe:bf:0f:39:1c, ttl 63
tap102-tx          buffer 0xf5851, current data 0, length 98, ref-count 1
                   l2-hdr-offset 0, l3-hdr-offset 14
```

同一次 `show trace` 也捕获了 echo reply：`virtio-input -> ethernet-input -> ip4-input -> ip4-lookup (dpo-idx 4) -> ip4-rewrite (via 10.10.1.2 tap101) -> tap101-output -> tap101-tx`，回包 TTL 同样由 64 降到 63。两方向与 ping 成功结果相互印证。

`virtio-input` 从 Linux TAP/virtio 队列读 packet，形成供 graph 调度的 buffer；`ethernet-input` 看 L2 头并将 IPv4 packet 送到 `ip4-input`。`ip4-input` 做 IPv4 输入处理后将 frame 送到 `ip4-lookup`；后者使用 FIB 0 与 DPO index 5，选择已解析的 host adjacency。该版本 trace 未单列 `load-balance` node，但 Stage 3 的 FIB 显示 `dpo-load-balance -> ipv4 via 10.10.2.2 tap102`，这是同一步转发决策的控制状态证据。`ip4-rewrite` 应用 adjacency 的 14-byte L2 rewrite 并递减 TTL；`tap102-output` 到 `tap102-tx` 把转发路径交给 VIRTIO device output。trace 中的 `buffer 0xf5851`、offset 与 `ref-count 1` 是本次 packet buffer 状态；node 之间传的是 buffer index/frame，不需每个 node 复制完整 packet。trace 没有直接显示 frame 内所有 buffer indices，不能由这一次 packet 推断批量 vector 行为。

`show runtime` 的相关累计值：

| Node | Calls | Vectors | Vectors/Call |
| --- | ---: | ---: | ---: |
| `virtio-input` | 863273452 | 45 | 0.00（含空轮询） |
| `ethernet-input` | 43 | 45 | 1.05 |
| `ip4-input` | 17 | 17 | 1.00 |
| `ip4-lookup` | 17 | 17 | 1.00 |
| `ip4-rewrite` | 16 | 16 | 1.00 |
| `tap102-output` / `tap102-tx` | 11 / 11 | 11 / 11 | 1.00 / 1.00 |

这些是整个 VPP 实例启动后的累计值，含此前 Stage 3 流量；低流量下没有性能结论。`show threads` 只有 `ID 0 vpp_main, LWP 210136, lcore/core 7`，没有额外 worker 或跨 worker handoff；graph 的 next-node 在该 main thread 内继续处理。`clear errors` 后单包请求/回复的 `show errors` 只有表头，无新增 error 行。此前的 `null-node blackholed packets` 主要来自 TAP 自动 IPv6 流量及未启用 IPv6，不应与本次成功 IPv4 trace 混同。

### 最终从干净环境复验

清理旧拓扑并停止/重启独立 VPP 后，按顺序运行 `go run ./cmd/vpp-probe`、`setup-topology.sh`、`configure-forwarding.sh`、`test-forwarding.sh`、`capture-trace.sh`、`cleanup-topology.sh`。GoVPP 再次返回 `24.10-release`；首次 ICMP 3 发 2 收（ARP 首包），UDP 请求/确认成功；trace 的 1 发 1 收成功，实际 node path 与上述记录一致，`clear errors` 后只有表头。重启后 hw/sw interface index 和随机 TAP MAC 与上一次不同（请求 input index 1、output index 2，rewrite `02fe371dbf4102feb3a77bbe0800`），这说明脚本依赖接口名而非固定 index/MAC。最终 `ip netns list` 为空、VPP 仅 `local0`、ownership marker 消失；host default route 仍是 `default via 10.0.138.1 dev eth0 proto static`，`eth0` 仍为 `UP d8:88:ef:00:01:c6 10.0.138.51/24`。
