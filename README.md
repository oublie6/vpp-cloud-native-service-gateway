# VPP Cloud-Native Service Gateway

一个面向 **云原生容器网络 / 云网络数据面研发** 的 VPP / GoVPP 学习与工程项目。

本仓库承接前序 `dpdk-high-speed-flow-router` 项目：前序项目负责从零理解和实现 RXQ/TXQ、mbuf、RTC、hash/LPM、multi-lcore、RCU/QSBR 等高性能数据面基础；本项目不再重复实现 packet loop，而是转向学习 **成熟工业级 dataplane 如何组织 graph、worker、FIB、adjacency、feature、service/NAT，以及 Go 控制面如何通过 Binary API 驱动 VPP**。

最终目标不是做一个 VPP CLI demo，而是完成一个可以用于求职展示的：

> **Kubernetes VPP Service Dataplane / Cloud-Native L4 Service Gateway**

---

## 1. 最终目标架构

~~~text
Kubernetes API
  ├─ Service
  └─ EndpointSlice
        |
        v
+------------------------------+
| Go Controller                |
|                              |
| informer / watcher           |
| desired-state store          |
| reconciler                   |
| idempotent update            |
+---------------+--------------+
                |
              GoVPP
                |
          VPP Binary API
                |
                v
+-----------------------------------------------+
| VPP Dataplane                                 |
|                                               |
| interface input                               |
|      |                                        |
|      v                                        |
| service / CNAT lookup                         |
|      |                                        |
| backend selection                             |
|      |                                        |
| rewrite / translation                         |
|      |                                        |
| FIB / adjacency                               |
|      |                                        |
| interface output                              |
+----------------------+------------------------+
                       |
                  TAP / AF_PACKET / memif
                       |
                Linux / Kubernetes

后续具备真实 NIC 条件后，可再评估 DPDK device backend：

NIC -> DPDK PMD -> VPP graph -> Service/FIB -> output
~~~

核心原则：

~~~text
Go 负责控制面
VPP 负责 packet dataplane
GoVPP 负责 Binary API 边界
Kubernetes 负责 desired state 来源
~~~

Go 不逐包处理，也不通过 cgo 自己再写一套 DPDK RX/TX loop。

---

## 2. 为什么做这个项目

前序 DPDK 项目已经解决了“底层为什么这么做”的问题：

- RX/TX queue ownership；
- mbuf / mempool ownership；
- Run-To-Completion；
- RSS / flow affinity；
- NUMA / cache locality；
- exact-flow hash / IPv4 LPM；
- DROP / FORWARD / REWRITE；
- multi-lcore；
- immutable snapshot；
- RCU / QSBR；
- benchmark 与 failure cleanup。

本项目要解决下一层问题：

1. VPP 的 **vector / frame / graph / node** 与 DPDK burst/RTC 有什么关系；
2. VPP worker 如何组织 packet processing；
3. FIB、adjacency、DPO 等成熟转发抽象如何工作；
4. feature arc 如何把功能插入已有 graph，而不是自己写完整 packet loop；
5. VPP Binary API 如何把控制面和数据面解耦；
6. GoVPP 如何生成/使用 API bindings、调用 RPC、读取 stats；
7. VPP 现有 CNAT / Service 能力如何实现 VIP -> backend；
8. Kubernetes Service / EndpointSlice 如何转换成 VPP runtime state；
9. backend add/delete、scale in/out、失败恢复如何做到幂等 reconcile；
10. 双节点条件下 local/remote backend 的数据路径如何验证。

---

## 3. 项目最终功能

最终版本至少实现以下能力。

### 3.1 Go 控制面

Go controller 负责：

~~~text
Kubernetes Service / EndpointSlice
        |
        v
normalize desired state
        |
        v
ServiceStore / BackendStore
        |
        v
reconciler
        |
        v
GoVPP
        |
        v
VPP
~~~

至少支持：

- watch Service；
- watch EndpointSlice；
- Service add/update/delete；
- Backend add/update/delete；
- desired state 与 actual VPP state 的幂等 reconcile；
- VPP/GoVPP reconnect 后重新收敛；
- 日志、基础 metrics 与可诊断状态。

### 3.2 VPP Service Dataplane

第一版优先复用 VPP 已有能力，而不是重新实现成熟组件。

目标包括：

- IPv4 TCP/UDP VIP；
- 多 backend；
- Service -> backend selection；
- L3/L4 rewrite / translation；
- VPP FIB forwarding；
- local backend；
- cross-node backend；
- backend 动态增删；
- 多 worker 条件下功能验证；
- packet trace / node counter / interface counter 诊断。

负载分配优先研究 VPP 现有 CNAT / load-balancing 能力；如果当前 VPP 版本的 CNAT/API 与目标不完全匹配，再基于真实能力调整设计，禁止在不了解现有机制的情况下先重造一套 LB/NAT。

### 3.3 Kubernetes 双节点实验

至少使用两个节点验证：

~~~text
Client / test namespace
        |
      VIP
        |
      VPP
     /   \
local   remote
backend backend
~~~

至少覆盖：

- 同节点 backend；
- 跨节点 backend；
- EndpointSlice 增加 backend；
- EndpointSlice 删除 backend；
- Service 删除；
- controller/VPP 重启后的状态恢复；
- 同一个 flow 的 backend affinity（具体语义依据最终 LB 实现）；
- 多 flow distribution；
- packet trace 与状态验证。

---

## 4. kube-proxy 共存策略

项目早期 **不直接全局替换 kube-proxy**。

先采用隔离测试 VIP 范围，例如：

~~~text
普通 Kubernetes Service CIDR
    -> 现有 kube-proxy / CNI 继续负责

VPP test VIP CIDR
    -> 只由 VPP Service Dataplane 负责
~~~

原则：

> 同一个节点上的同一个 VIP，不允许 kube-proxy 和 VPP 同时宣称 ownership。

推荐逐步推进：

~~~text
Phase 1
kube-proxy 保持不动
+ 独立 VPP test VIP

Phase 2
Service / EndpointSlice 驱动 VPP test VIP

Phase 3
受控测试真实 ClusterIP Service

Phase 4
再评估局部或完整 kube-proxy replacement
~~~

不在第一阶段为了“看起来更完整”而破坏 CoreDNS、`kubernetes.default.svc` 等现有 Service。

---

## 5. 学习路线

本项目采用 **5 个较大的 Goal**，减少频繁切换任务，让每个阶段包含更多机制学习、源码理解、实验验证和工程实现。

~~~text
Goal 001
VPP Runtime / GoVPP / Graph / L3 Forwarding
+ 固定版本与环境
+ VPP 启动 / CLI / Binary API socket
+ GoVPP ShowVersion
+ interface / graph / node / frame / worker
+ TAP / network namespace
+ two-interface L3 forwarding
+ FIB / DPO / adjacency
+ packet trace / counters

        ↓

Goal 002
GoVPP Control Plane / FIB / Stats / CNAT Service
+ interface / route programming
+ FIB add/delete
+ Stats API
+ CNAT Translation / Backend / Session
+ VIP -> multiple backends
+ TCP / UDP
+ Maglev / session stickiness
+ reverse path / session lifecycle
+ dynamic backend add/delete

        ↓

Goal 003
Go Service Model / Reconciler / Kubernetes Integration
+ desired state / actual state
+ idempotent reconcile
+ reconnect / recovery
+ Service informer
+ EndpointSlice informer
+ Kubernetes -> Go -> GoVPP -> VPP

        ↓

Goal 004
Two-Node Service Dataplane / Recovery / Observability
+ local / remote backend
+ scale in / scale out
+ Service / Backend delete
+ VPP restart
+ GoVPP reconnect
+ controller restart
+ trace / counters / stats
+ troubleshooting
+ software benchmark

        ↓

Goal 005
Small Custom VPP Plugin / Finalization
+ node registration
+ frame / buffer traversal
+ next-node
+ feature arc
+ trace / counters
+ custom Binary API
+ GoVPP custom API
+ architecture / troubleshooting / benchmark docs
+ final project summary
~~~

所有 5 个 Goal 都计划完成，Goal 005 不再作为可选项。

Goal 可以根据实际版本和实验结果调整内部 stage，但不得跳过机制学习直接堆最终功能。

---

## 6. 与前序 DPDK 项目的关系

~~~text
P4 / P4Runtime
        ↓
DPDK High-Speed Flow Router
        ↓
VPP / GoVPP
        ↓
Kubernetes Service Dataplane
        ↓
Cloud Native / Cloud Network Dataplane
~~~

前序项目回答：

> 一个高性能用户态 dataplane 从 queue、mbuf、lookup、ownership 到 RCU/QSBR 应该怎么自己实现？

本项目回答：

> 一个成熟工业 dataplane 如何用 graph、worker、FIB、feature、Binary API 和控制面协同，把这些机制组织成可扩展网络系统？

因此本项目不会为了“代码更多”而重复实现已经封板的 DPDK Flow Router。

---

## 7. Non-goals

本仓库现阶段明确不做：

- 从零重写 DPDK RX/TX loop；
- 自己实现完整 FIB；
- 自己实现 ARP/neighbor stack；
- 自己实现完整 NAT/CNAT；
- 自己实现完整 Maglev/LB framework，除非后续 Goal 明确需要并有充分理由；
- 完整 CNI replacement；
- 完整 Calico/Cilium replacement；
- L7 proxy；
- TCP termination；
- service mesh；
- Envoy 替代品；
- Web frontend；
- 大规模 CRD framework；
- 生产级 HA control plane。

优先保证主线：

> **Kubernetes desired state -> GoVPP -> VPP Service Dataplane**

---

## 8. 与 Calico-VPP 的关系

Calico-VPP 可以作为参考实现和源码教材，但本项目不直接以“fork Calico-VPP 改几行”为主要交付方式。

重点参考：

~~~text
Kubernetes Service state
        |
        v
service handler / reconciler
        |
        v
VPP link / API
        |
        v
CNAT / forwarding
~~~

本仓库保持实现范围小、路径清晰，使每一层都能解释、测试和独立验收。

---

## 9. 预期仓库结构

~~~text
.
├── AGENTS.md
├── README.md
├── cmd/
│   └── vpp-service-agent/
├── internal/
│   ├── controller/
│   ├── model/
│   ├── reconcile/
│   └── vpp/
├── pkg/
├── deploy/
│   ├── vpp/
│   └── kubernetes/
├── scripts/
├── docs/
│   ├── goals/
│   ├── architecture.md
│   ├── learning-notes.md
│   └── troubleshooting.md
├── tests/
└── results/
~~~

不要求第一天就创建所有目录；目录随 Goal 推进逐步落地。

---

## 10. 工程与学习原则

1. **机制优先**：每个 Goal 不只是“跑通”，还要能解释 packet/control path。
2. **复用成熟能力**：优先理解和调用 VPP 已有 FIB/CNAT/feature，再决定是否扩展。
3. **版本可追溯**：VPP、GoVPP、Go、Kubernetes 版本必须记录。
4. **software evidence != hardware evidence**：软件 TAP/AF_PACKET benchmark 不宣称真实 NIC 性能。
5. **控制面幂等**：Kubernetes controller 必须围绕 desired state/reconcile 设计，而不是堆命令式 API 调用。
6. **故障路径必须验证**：VPP 重启、GoVPP disconnect、backend 删除等不能只测 happy path。
7. **小步 Goal**：一个 Goal 解决一组紧密相关的问题，完成后由 ChatGPT 验收再继续。

---

## 11. 当前状态

~~~text
DPDK High-Speed Flow Router v0.1      ✅ 已封板

VPP Cloud-Native Service Gateway
└─ Repository bootstrap              ✅
   └─ Goal 001                       🟡 已设计，待实现
~~~

下一步不是直接写 Kubernetes controller。

**Goal 001 从 VPP/GoVPP 环境基线开始，并继续完成 graph/node/frame/worker 学习、软件接口拓扑、两接口 L3 forwarding、FIB/DPO/adjacency 与真实 packet trace。**

Goal 001 已设计：`docs/goals/001-vpp-govpp-environment-baseline.md`。

具体 Goal 由 ChatGPT 设计并验收，Codex 按 `AGENTS.md` 执行。
