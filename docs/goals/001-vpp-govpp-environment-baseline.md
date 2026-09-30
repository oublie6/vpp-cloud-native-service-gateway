# Goal 001：VPP Runtime / GoVPP / Graph / L3 Forwarding

## 1. Goal 定位

这是项目的第一个完整工程学习阶段。

本 Goal 不再只做“环境搭建”，而是从 VPP/GoVPP 最小控制链开始，一直推进到真实软件接口 L3 forwarding 和 packet trace。

最终要把此前理论中的：

```text
Go Controller
-> GoVPP
-> VPP Binary API
-> VPP runtime

packet
-> interface input
-> frame
-> node
-> ip4 lookup
-> FIB
-> DPO
-> adjacency
-> rewrite
-> interface output
```

全部映射到真实代码、CLI state、packet trace 和 counters。

本 Goal 采用 **分 Stage 学习**，Codex 不应一次性把所有内容实现完。

---

## 2. 总体学习目标

完成后应能够解释并用真实证据证明：

1. VPP process、startup config、CLI socket、Binary API socket 的关系；
2. GoVPP 如何通过 Binary API 调用 `ShowVersion`；
3. VPP 的 hw interface / sw interface 基本关系；
4. TAP / Linux namespace / VPP interface 如何组成软件实验拓扑；
5. packet 进入 VPP 后如何形成 frame，并由 node 批处理；
6. graph edge、next node 与 worker 的关系；
7. 为什么同一 worker 内 graph forwarding 不等于跨 CPU pipeline；
8. IPv4 route 如何从 RIB/FIB 解析成 LB DPO / adjacency 等 dataplane state；
9. neighbor 未解析时为何会出现 glean / incomplete adjacency；
10. packet 如何完成 L2 rewrite 并从 output interface 发出；
11. packet trace、interface counter、node counter、error counter 分别能证明什么。

---

## 3. 版本策略

### VPP

优先使用稳定 release line，不追 master。

当前目标优先：

```text
VPP 26.06
```

如果实际 OS / 官方 package source 无法可靠获得该版本：

- 先记录环境和失败原因；
- 使用当前官方可获得的最近稳定版本；
- 在 evidence 中明确偏差；
- 不允许为了“装上就行”随机切换版本。

### GoVPP

首选：

```text
go.fd.io/govpp v0.13.0
```

但必须通过真实 VPP API 验证 schema compatibility。

后续如果出现 message CRC / schema mismatch：

- 不通过 shell CLI 绕过；
- 优先使用目标 VPP 对应 API JSON 重新生成 bindings；
- 记录来源与生成命令。

### Environment evidence

必须记录：

- OS；
- kernel；
- arch；
- Go；
- VPP；
- GoVPP；
- VPP runtime/socket paths。

---

# Stage 1：VPP Runtime + GoVPP Binary API Baseline

## 4. Stage 1 目标

建立：

```text
Go vpp-probe
-> GoVPP
-> Binary API socket
-> VPP
-> ShowVersionReply
```

### 实现

建议新增：

```text
scripts/goal001/inspect-env.sh
scripts/goal001/start-vpp.sh
scripts/goal001/stop-vpp.sh
deploy/vpp/startup-goal001.conf
cmd/vpp-probe/main.go
results/goal001/README.md
```

要求：

- 不接管管理 NIC；
- 不配置 VFIO；
- 不修改 HugePages；
- 不要求 DPDK PMD；
- API socket path 可配置；
- `vpp-probe` 必须使用 GoVPP Binary API；
- 禁止用 `exec.Command("vppctl")` 模拟控制面。

### Stage 1 evidence

至少包括：

```text
OS / kernel / arch
Go version
VPP exact version
GoVPP version
VPP process
CLI socket
Binary API socket
show version
show interface
show runtime
show errors
vpp-probe success
invalid api.sock failure + non-zero exit
go test ./...
go vet ./...
bash -n scripts/goal001/*.sh
```

### Stage 1 学习检查点

Codex 完成 Stage 1 后停止。

ChatGPT 重点讲解：

- CLI socket vs Binary API socket；
- `govpp.Connect` / socketclient；
- connection / channel / request context；
- message name + CRC；
- request / reply matching；
- 为什么 CLI 是 debug plane 而 GoVPP 是正式控制边界。

---

# Stage 2：Software Interface Topology

## 5. Stage 2 目标

建立安全的软件接口实验拓扑。

优先使用：

```text
Linux namespace
<-> TAP / AF_PACKET / host-interface
<-> VPP
<-> TAP / AF_PACKET / host-interface
<-> Linux namespace
```

具体 I/O backend 根据当前 VPP 版本、主机能力和实现复杂度决定，但必须：

- 不接管管理 NIC；
- 不改变默认路由；
- cleanup 可重复；
- 每个接口、namespace、IP 都可解释；
- 所有创建动作都有对应删除动作。

### Stage 2 学习内容

重点理解：

- Linux TAP 是什么；
- VPP hw interface vs sw interface；
- interface index；
- admin up/down；
- L2/L3 interface state；
- packet 从 Linux fd/device 进入 VPP 的边界；
- 为什么普通云服务器仍可完成软件 dataplane 学习。

### Stage 2 evidence

至少：

- Linux namespace/interface topology；
- VPP `show interface`；
- Linux `ip link` / `ip addr`；
- setup/cleanup scripts；
- cleanup 后主机状态恢复。

完成后停止，进行学习验收。

---

# Stage 3：Two-Interface L3 Forwarding

## 6. Stage 3 目标

让真实 packet 穿过 VPP。

示意：

```text
ns-client
  |
 interface A
  |
 VPP
  |
 interface B
  |
ns-server
```

配置：

- 两侧 IPv4 subnet；
- VPP interface addresses；
- 必要 route；
- neighbor resolution；
- client -> server ping / UDP packet。

不能只验证“ping 通”，还必须观察 forwarding state。

### Stage 3 学习内容

重点解释：

```text
RIB intent
-> FIB entry
-> Load-Balance DPO
-> adjacency
-> rewrite
-> output
```

以及：

- connected route；
- attached prefix；
- glean adjacency；
- neighbor adjacency；
- incomplete -> complete；
- ARP 请求为什么不是原业务 packet 等待；
- complete adjacency 保存什么 rewrite state。

### Stage 3 evidence

至少：

- route table；
- FIB state；
- neighbor state；
- adjacency state；
- ping / UDP E2E；
- interface RX/TX counters；
- packet capture（如需要，仅保存紧凑证据）。

完成后停止，进行学习验收。

---

# Stage 4：Graph / Frame / Node / Worker + Packet Trace

## 7. Stage 4 目标

把 Stage 3 已经跑通的真实 packet 用 VPP trace 还原。

至少捕获一条成功 forwarding path。

要求能够从 trace 中辨认主要阶段，例如：

```text
interface/device input
-> ethernet/input
-> ip4-input
-> ip4-lookup
-> forwarding/DPO path
-> rewrite/output
```

实际 node 名称以当前 VPP 版本真实 trace 为准，不硬编码预期。

### Stage 4 学习内容

重点解释：

- `vlib_buffer_t`；
- buffer index；
- vector；
- frame；
- node function；
- next node；
- graph runtime；
- worker；
- node graph vs DPO graph；
- frame 在 node 之间传递的是 buffer indices，不是 packet payload copy；
- VPP graph 为什么仍然保持 RTC/cache locality；
- 什么情况下才会 handoff / frame queue 到其他 worker。

### Stage 4 evidence

至少：

- `show runtime`；
- `show node counters` 或版本对应命令；
- packet trace；
- interface counters；
- error counters；
- worker/thread state；
- 对 trace 各关键 node 的中文解释。

---

## 8. Goal 001 Non-goals

本 Goal 不进入：

- GoVPP route programming；
- Stats API 正式封装；
- CNAT / NAT；
- VIP / backend；
- Kubernetes；
- Service / EndpointSlice；
- reconciler；
- two-node；
- throughput benchmark；
- DPDK NIC / VFIO；
- RSS/RETA；
- custom VPP plugin。

CLI 可以用于配置 Stage 2/3 实验拓扑，因为当前重点是 dataplane 机制。

从 Goal 002 开始，route/service 等正式控制操作逐步切换为 GoVPP。

---

## 9. 工程约束

- 所有 host/network 修改必须最小化并可 cleanup；
- 不允许修改管理 NIC ownership；
- 不允许修改主机默认路由；
- 不允许关闭系统 firewall 作为“解决方案”；
- 不允许为了 ping 通做无法解释的 sysctl 大改；
- 不允许提交 credentials、private key、kubeconfig；
- 大 pcap / 大日志不提交；
- software evidence 不表述为 hardware performance。

---

## 10. Codex 工作节奏

这是一个大 Goal，但 **禁止一次性全部完成**。

执行顺序固定：

```text
Stage 1
-> Codex 实现
-> 提交 focused commit
-> 输出 evidence
-> STOP

ChatGPT 学习验收

Stage 2
-> implement
-> evidence
-> STOP

ChatGPT 学习验收

Stage 3
-> implement
-> evidence
-> STOP

ChatGPT 学习验收

Stage 4
-> implement
-> evidence
-> STOP

ChatGPT 最终验收 Goal 001
```

除非用户明确要求，否则 Codex 不允许提前实现后续 Stage。

---

## 11. 每个 Stage 的通用验收

至少：

```bash
git diff --check
git status --short
go test ./...
go vet ./...
bash -n scripts/goal001/*.sh
```

以及当前 Stage 对应的真实 runtime evidence。

---

## 12. Codex 实现记录

### Stage 1
状态：🟡 Codex 已实现并提交，待 ChatGPT 学习/工程验收

- 原生 Ubuntu 20.04 / kernel `5.4.0-216-generic` / amd64；主机 Go 已升级到 `1.24.13`。focal 官方 release APT 仓库最高稳定 VPP 为 `24.10-release`，与优先目标 `26.06` 有版本偏差；固定 GoVPP `v0.13.0`。
- 新增独立 VPP startup config、环境检查和启停脚本，以及通过 `govpp.Connect` 和生成的 `vpe` RPC client 发出 `ShowVersion` 的 Go probe。socket 路径可由 `-api-socket` 或 `VPP_API_SOCKET` 指定。
- 本机 VPP API JSON 与 GoVPP 的 `ShowVersionReply` CRC 一致；真实 API socket 请求成功。完整命令与实际输出见 `results/goal001/README.md`。
- CLI socket 提供 `vppctl` 的文本调试入口；Binary API socket 提供 GoVPP 的消息接口。`govpp.Connect` 用 socketclient 建立连接；`Connection` 管理底层连接，API Channel/RPC client 承载请求与响应。`ShowVersion` request 经消息名和 CRC 匹配 VPP schema，reply 通过 context 对应请求。schema/CRC 不匹配时可能无法解析消息或请求失败，不能用 CLI 假装成功。
- 本阶段只检查 VPP runtime 和控制 API，不接 NIC、也不转发 packet，因此不需要 DPDK NIC。`vppctl` 可交叉检查状态，但正式 Go 控制面使用 Binary API，可获得类型化回复和明确错误。
- 包安装曾自动启动默认服务并设置 HugePages；已停用默认服务、将当前及持久配置的 HugePages 值恢复为 0。后续使用独立实例，未配置 NIC、VFIO、路由或 firewall。

### Stage 2
状态：⬜ 待实现

### Stage 3
状态：⬜ 待实现

### Stage 4
状态：⬜ 待实现

---

## 13. ChatGPT 学习 / 工程验收

### Stage 1
状态：⬜ 未验收

### Stage 2
状态：⬜ 未验收

### Stage 3
状态：⬜ 未验收

### Stage 4
状态：⬜ 未验收

### Goal 001 总体验收
状态：⬜ 未验收

---

## 14. Goal 001 完成后的下一步

进入：

> **Goal 002：GoVPP Control Plane / FIB / Stats / CNAT Service**

重点从“观察和 CLI 建立 dataplane”升级到：

```text
Go intent
-> GoVPP
-> Binary API
-> VPP FIB / CNAT state
-> packet fast path
```
