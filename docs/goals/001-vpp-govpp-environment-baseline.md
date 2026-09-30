# Goal 001：VPP / GoVPP Environment Baseline

## 1. 背景

本 Goal 是 `vpp-cloud-native-service-gateway` 的第一个工程 Goal。

前序理论阶段已经建立以下模型：

```text
Go Controller
-> GoVPP
-> VPP Binary API
-> VPP dataplane
```

本阶段不进入 CNAT、Kubernetes Service 或复杂转发逻辑，而是先建立一个可重复、可诊断、版本可追溯的 VPP / GoVPP 最小真实运行闭环。

完成后需要能够回答并用运行证据证明：

1. 当前主机运行的 VPP 是什么版本；
2. VPP 如何启动、CLI 如何连接；
3. Binary API socket 在哪里；
4. GoVPP 如何连接这个 socket；
5. `ShowVersion` request/reply 如何完成；
6. VPP 当前有哪些 interface、基本 graph/node/trace 命令如何观察；
7. VPP 未启动或 API socket 不存在时，Go 程序如何明确失败；
8. 当前 GoVPP bindings 与实际 VPP API 是否至少能完成本 Goal 所需的兼容性验证。

---

## 2. 学习目标

### 2.1 VPP runtime baseline

理解并验证：

```text
vpp process
-> startup.conf
-> runtime dir
-> CLI socket
-> Binary API socket
-> plugins
-> interfaces / nodes / counters
```

重点不是记命令，而是明确：

- CLI socket 与 Binary API socket 是两条不同控制通道；
- `vppctl` 用于 debug / trace / 交叉验证；
- GoVPP 通过 Binary API 与 VPP 通信；
- interface / node / trace 是后续 packet path 验证的观测入口。

### 2.2 GoVPP connection baseline

理解并验证：

```text
Go process
-> govpp.Connect(api.sock)
-> socketclient
-> Binary API handshake
-> API channel
-> ShowVersion request
-> ShowVersionReply
```

至少能解释：

- socket path 从哪里来；
- connection 与 API channel 的关系；
- request/reply 如何匹配；
- API message name/CRC 不兼容时为什么会失败；
- 为什么正式控制面不能依赖 shell 调 `vppctl`。

---

## 3. 版本策略

### 3.1 VPP

优先目标：

```text
VPP 26.06 stable/release line
```

原因：

- 本项目需要稳定、可复现的基线；
- 不追 VPP master；
- 后续 CNAT / Binary API 学习需要固定 schema。

如果当前 OS / 官方 package repository 无法可靠安装 26.06：

1. 不允许随机换版本直到“能跑”；
2. 记录 OS、package repository 和失败原因；
3. 选择当前官方可获得的最近稳定 release；
4. 在 Goal 实现记录中明确偏差及原因。

禁止直接使用 `master` 作为默认基线。

### 3.2 GoVPP

首选：

```text
go.fd.io/govpp v0.13.0
```

但必须把“能编译”与“API schema 兼容”分开验证。

本 Goal 只要求：

- 能连接实际 VPP Binary API socket；
- `ShowVersion` request/reply 成功；
- 记录 GoVPP module version；
- 记录所使用 binapi package 的来源。

如果 v0.13.0 的 bundled binapi 与 VPP 26.06 在本 Goal 已出现 message CRC/API mismatch，则：

- 不允许通过 shell 命令绕过；
- 优先使用实际 VPP 安装/源码对应的 API JSON 重新生成 bindings；
- 记录 API JSON 来源与生成命令；
- 固定生成结果和依赖版本。

后续 Goal 003/004 在使用 route/CNAT API 前必须再次检查 schema 匹配。

### 3.3 Go / OS / kernel

不在 Goal 文档中猜主机环境。

Codex 首先采集：

```bash
cat /etc/os-release
uname -a
go version || true
```

最终 evidence 必须记录：

- OS distribution / version；
- kernel；
- CPU architecture；
- Go version；
- VPP version；
- GoVPP version。

---

## 4. 实现范围

### 4.1 Environment inspection

新增一个小型脚本，例如：

```text
scripts/goal001/inspect-env.sh
```

输出必要环境信息：

- OS / kernel / arch；
- Go；
- VPP package/version；
- VPP process；
- CLI socket；
- Binary API socket；
- VPP runtime directory。

脚本不得修改系统状态。

### 4.2 VPP baseline config

在仓库中保存最小、可解释的 VPP 配置模板，例如：

```text
deploy/vpp/startup-goal001.conf
```

目标：

- 可以在普通云服务器/VM 上启动；
- 不绑定管理网卡；
- 不要求 VFIO / hugepage / DPDK NIC；
- 保留 Binary API；
- 允许 CLI 观察；
- 路径、日志和 runtime directory 明确。

不要为了 Goal 001 开启不需要的复杂 plugin 或性能参数。

### 4.3 VPP lifecycle helper

允许新增小型脚本帮助：

- 检查配置；
- 启动测试 VPP；
- 检查 process；
- 检查 sockets；
- 停止测试实例；
- cleanup Goal 001 自己创建的 runtime artifact。

不得：

- kill 用户已有未知 VPP instance；
- 改默认路由；
- bind/unbind NIC；
- 改 firewall；
- 改系统 HugePages/VFIO。

### 4.4 GoVPP minimal client

新增最小 Go 程序，建议：

```text
cmd/vpp-probe/
```

要求：

- API socket path 可通过 flag 或 environment 指定；
- 默认值可以指向常见路径，但不得把 host-specific 路径写死；
- 使用 GoVPP 正式 API；
- 发起 `ShowVersion`；
- 输出至少：
  - VPP program/version；
  - build date；
  - build directory（如果 reply 提供）；
  - GoVPP version；
  - API socket path；
- error 必须带上下文；
- process exit code 在失败时非 0。

禁止通过：

```text
exec.Command("vppctl", ...)
```

模拟 Binary API client。

### 4.5 CLI / interface / graph / trace baseline

本 Goal 不要求真实双口 L3 forwarding，但必须熟悉最小观测命令并保存结果摘要。

至少检查：

```text
show version
show interface
show hardware
show runtime
show node counters
show errors
show plugins
```

trace 部分要求：

- 能启用/清除 trace；
- 如果没有合适 ingress packet，可以只证明 trace control 命令可用；
- 不允许编造 packet trace。

Goal 002 再建立 two-interface packet path 并要求真实 packet trace。

---

## 5. 明确 Non-goals

Goal 001 不做：

- Kubernetes controller；
- Service / EndpointSlice；
- CNAT / NAT；
- VIP -> backend；
- route programming；
- two-interface L3 forwarding；
- network namespace 拓扑；
- custom VPP plugin；
- DPDK PMD / VFIO；
- RSS / RETA；
- NUMA tuning；
- throughput benchmark；
- kube-proxy replacement。

如果执行过程中发现这些方向的机会，只记录为 follow-up，不顺手实现。

---

## 6. 建议仓库结构

完成后预计至少出现：

```text
.
├── cmd/
│   └── vpp-probe/
│       └── main.go
├── deploy/
│   └── vpp/
│       └── startup-goal001.conf
├── scripts/
│   └── goal001/
│       ├── inspect-env.sh
│       ├── start-vpp.sh
│       └── stop-vpp.sh
├── docs/
│   └── goals/
│       ├── README.md
│       └── 001-vpp-govpp-environment-baseline.md
├── results/
│   └── goal001/
│       └── README.md
├── go.mod
└── go.sum
```

具体文件可根据实际环境小幅调整，但不得扩大 Goal 范围。

---

## 7. 实现步骤

### Step 0：同步仓库

严格执行 `AGENTS.md`：

```bash
git status --short
git branch --show-current
git fetch origin
git pull --ff-only origin main
```

若存在用户未提交修改、分叉或 pull 失败，停止并报告，不自动处理。

重新阅读：

- `AGENTS.md`
- `README.md`
- `docs/goals/README.md`
- 本 Goal

### Step 1：采集当前环境

采集并记录：

```bash
cat /etc/os-release
uname -a
uname -m
go version || true
which vpp || true
vpp --version || true
dpkg -l | grep -E '^ii +vpp' || true
rpm -qa | grep -i '^vpp' || true
```

不要先安装再记录旧状态。

### Step 2：确认安装来源并固定 VPP

根据实际 OS 使用 FD.io 当前官方支持的 package/source 流程。

目标优先 VPP 26.06。

安装或构建方式必须记录：

- repository/source；
- exact version；
- package list 或 commit/tag；
- startup config path。

如果当前环境已经存在合适 VPP，优先复用并记录，不做无意义重装。

### Step 3：启动隔离测试 VPP

要求：

- 不接管管理 NIC；
- 明确 PID；
- 明确 CLI socket；
- 明确 Binary API socket；
- 能通过 CLI 查看 version/interface/runtime；
- cleanup 可控。

必须证明：

```bash
ps ...
ls -l <api socket>
vppctl ... show version
```

实际命令根据最终 runtime path 调整。

### Step 4：建立 Go module 和 vpp-probe

程序最小职责：

```text
parse api socket
-> connect
-> create API channel/client
-> ShowVersion
-> print structured result
-> close cleanly
```

保持代码直接，不提前抽象 controller/reconciler interface。

### Step 5：验证成功路径

至少：

```bash
go test ./...
go vet ./...
go run ./cmd/vpp-probe --api-socket <actual socket>
```

输出必须来自真实 VPP reply，不得 hard-code。

### Step 6：验证失败路径

至少验证一次：

```text
invalid/nonexistent API socket
-> connect fails
-> clear contextual error
-> non-zero exit
```

如停止 VPP 验证 disconnect 会破坏当前环境，可使用不存在 socket 路径完成本 Goal 的失败路径。

### Step 7：CLI / graph / trace baseline

保存紧凑 evidence：

- `show version`；
- `show interface`；
- `show runtime`；
- `show node counters` 或等价当前版本命令；
- `show errors`；
- trace enable/clear 的实际可用命令；
- Binary API socket 文件；
- vpp-probe output。

大日志不要提交。

### Step 8：文档和 cleanup

在 `results/goal001/README.md` 记录：

- Environment；
- Versions；
- Startup method；
- API socket；
- GoVPP invocation；
- Success evidence；
- Failure evidence；
- CLI observations；
- Limitations；
- Cleanup；
- Open questions。

---

## 8. 验收标准

### 8.1 Repository

```bash
git diff --check
git status --short
go test ./...
go vet ./...
bash -n scripts/goal001/*.sh
```

如果某命令因实际文件布局不适用，需要在实现记录说明。

### 8.2 VPP runtime

必须有真实证据证明：

- VPP process 正在运行；
- exact VPP version 已记录；
- CLI 可连接；
- Binary API socket 存在；
- `show version` 成功；
- `show interface` 成功；
- runtime/node/error 基础信息可读取。

### 8.3 GoVPP

必须有真实证据证明：

```text
vpp-probe
-> connect actual api.sock
-> ShowVersion request
-> ShowVersionReply
-> print actual VPP version
```

同时验证不存在 socket 时返回明确错误和非 0 exit。

### 8.4 Explanation

Codex 实现记录必须能够解释：

1. CLI socket 与 Binary API socket 的区别；
2. `govpp.Connect` 到 socketclient 的关系；
3. connection / API channel / request-reply 的关系；
4. `ShowVersion` 为什么是一个真正的 Binary API 调用，而不是 CLI wrapper；
5. API message CRC/schema mismatch 的意义；
6. 为什么本阶段不用 DPDK NIC 仍然可以验证 VPP/GoVPP 控制链；
7. Goal 001 与 Goal 002 的边界。

---

## 9. 必须提供的 evidence

最终实现记录至少贴出紧凑输出：

```text
A. git status / branch / HEAD
B. OS + kernel + arch
C. Go version
D. VPP exact version
E. GoVPP exact version
F. VPP process
G. CLI socket / Binary API socket
H. show version
I. show interface
J. show runtime / node counters / errors 的关键摘要
K. vpp-probe success output
L. vpp-probe invalid-socket failure output + exit code
M. go test ./...
N. go vet ./...
O. bash -n ...
P. cleanup result
```

禁止只写“已验证通过”。

---

## 10. Codex 实现记录

状态：⬜ 待实现

实现完成后补充：

- 日期；
- commit；
- 环境；
- 版本；
- 关键设计；
- 测试；
- evidence；
- 偏差；
- open questions。

---

## 11. ChatGPT 验收结论

状态：⬜ 未验收

只有在读取最新远端代码和真实运行 evidence 后才能修改。

---

## 12. 下一步

Goal 001 验收通过后进入：

> **Goal 002：VPP graph / frame / node / worker + two-interface L3 forwarding + packet trace**

Goal 002 将第一次把理论中的：

```text
interface input
-> frame
-> node
-> ip4 lookup
-> DPO / adjacency
-> output
```

映射到真实 packet trace 和 interface/node counters。
