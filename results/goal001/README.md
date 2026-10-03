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
