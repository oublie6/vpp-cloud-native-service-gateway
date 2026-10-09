# AGENTS.md

本文件定义 `vpp-cloud-native-service-gateway` 仓库中 Codex / Agent 的长期工作规则。

项目目标不是快速堆功能，而是以可解释、可测试、可追溯的方式完成：

> **Kubernetes Service / EndpointSlice -> Go Controller -> GoVPP -> VPP Service Dataplane**

后续 Agent 必须优先遵守本文，而不是根据单次提示词自行扩大范围。

---

## 1. 协作模式

本项目默认工作流：

~~~text
ChatGPT
-> 设计 Goal / 学习重点 / 验收标准

Codex
-> 同步最新 main
-> 阅读 Goal
-> 实现
-> 测试
-> 文档
-> focused commit

ChatGPT
-> 阅读最新代码和证据
-> 解释机制
-> 验收
-> 决定下一 Goal
~~~

Codex 不得自行创建下一 Goal，不得在完成当前 Goal 后继续“顺手扩展”。

---

## 2. 每次执行前必须同步 Git

每次任务开始前必须执行：

~~~bash
git status --short
git branch --show-current
git fetch origin
git pull --ff-only origin main
~~~

规则：

- 必须基于远端最新 `main`；
- 工作区存在未提交修改时，不允许覆盖、丢弃、自动 stash；
- `git pull --ff-only` 失败、分叉或冲突时立即停止并报告；
- 禁止 `git reset --hard`；
- 禁止 force push；
- 禁止未经确认的 rebase；
- 禁止覆盖用户本地未提交内容。

同步后重新阅读：

~~~text
AGENTS.md
README.md
当前 Goal
docs/architecture.md（存在时）
相关上一 Goal 验收记录
~~~

不能依赖旧 clone、旧聊天上下文或旧 Goal 继续开发。

---

## 3. 当前项目边界

### 3.1 Go 是控制面，不是 packet hot path

目标：

~~~text
Go controller
-> GoVPP
-> VPP Binary API
-> VPP dataplane
~~~

禁止重新实现：

~~~text
Go
-> cgo
-> 自己写 rte_eth_rx_burst/rte_eth_tx_burst
~~~

前序 DPDK 项目已经完成这部分学习，本项目必须转向 VPP 架构。

### 3.2 VPP owns dataplane

packet parse、FIB、adjacency、feature、CNAT/service、worker graph 等优先使用 VPP 现有框架。

只有当前 Goal 明确要求时才新增自定义 VPP plugin。

禁止为了“证明会写 C”而重写：

- FIB；
- ARP / neighbor；
- CNAT/NAT；
- 完整 Service LB；
- 通用 graph engine。

### 3.3 GoVPP 是正式控制边界

Go 与 VPP 主要通过：

- Binary API；
- generated binapi / RPC；
- Stats API；
- 必要时 event/notification。

禁止大量依赖 `vppctl` shell command 作为正式控制面实现。

CLI 可用于学习、debug、trace、验收交叉检查；项目控制面最终必须通过 GoVPP/Binary API。

---

## 4. 版本与 API 兼容性

VPP / GoVPP API 会变化。

每个涉及 GoVPP bindings 的 Goal 必须明确记录：

~~~text
VPP version
GoVPP version / module version
Go version
OS / kernel
Kubernetes version（进入 K8s 阶段后）
~~~

原则：

- 优先使用稳定 release，不默认追 `master`；
- GoVPP bindings 必须与实际 VPP API schema 匹配；
- 如需自行生成 binapi，必须记录 API JSON 来源和生成命令；
- 不允许为了编译通过随机升级/降级依赖；
- 版本调整必须写入 Goal 实现记录；
- 涉及当前版本、安装命令、CNAT API 等内容时，先查官方文档或实际安装环境，不凭旧博客猜测。

---

## 5. 第一阶段 I/O 边界

当前主要运行环境是普通云服务器 / 虚拟机。

第一阶段允许：

- TAP；
- AF_PACKET；
- memif；
- Linux network namespace；
- software VPP dataplane。

第一阶段禁止为了性能展示主动引入：

- VFIO；
- 管理网卡 bind/unbind；
- hardware RSS/RETA；
- SmartNIC；
- RDMA；
- cross-NUMA tuning。

以后如果有真实 NIC，必须单独设计硬件 Goal。

software benchmark 只能表述为 software evidence，禁止写成 line-rate 或真实 NIC 性能。

---

## 6. Kubernetes 集成原则

进入 Kubernetes 阶段后，必须采用 desired-state / reconcile 模型：

~~~text
Service informer
EndpointSlice informer
        |
        v
internal desired state
        |
        v
reconciler
        |
        v
GoVPP operations
        |
        v
VPP actual state
~~~

要求：

- add/update/delete 幂等；
- duplicate event 不应破坏状态；
- event 顺序变化不能让状态永久错误；
- VPP 重启/GoVPP reconnect 后可以重新 reconcile；
- 不把 Kubernetes informer callback 直接写成一长串不可恢复的命令式 VPP 操作。

### kube-proxy coexistence

项目早期必须使用隔离 VPP test VIP 或其他明确流量引导方式。

禁止在同一个节点上让 kube-proxy 和 VPP 同时拥有同一个 VIP，而不说明冲突处理。

不允许第一阶段全局关闭 kube-proxy，除非当前 Goal 已经证明 CoreDNS、API Service 等关键依赖不会被破坏。

---

## 7. VPP 学习重点

Agent 在实现功能时，需要保留足够证据支持学习：

~~~text
vlib / vnet
vector / frame / buffer
graph / node / next node
worker
feature arc
FIB
adjacency
DPO
CNAT / Service
Binary API
Stats API
packet trace
~~~

如果一个 Goal 只是“CLI 能 ping 通”，但无法解释 packet 经过哪些 graph/node 或 control state 如何写入 VPP，则不算完整学习成果。

---

## 8. 自定义 VPP plugin 规则

自定义 plugin 是后置学习内容，不是项目起点。

只有在：

1. 已理解现有 VPP graph/feature；
2. 主 Service dataplane 已经跑通；
3. 当前能力确实无法通过现有 VPP feature/plugin 完成；

或者当前 Goal 明确用于学习 plugin 开发时，才写 plugin。

首个 plugin 应保持很小，例如：

- service stats；
- classify / mark；
- observability feature node。

plugin 必须至少包含：

- node registration；
- frame/buffer traversal；
- next-node 逻辑；
- trace 或 counter；
- Binary API（如果有控制参数）；
- GoVPP 调用测试。

---

## 9. 代码风格

优先级：

~~~text
清晰
> 可解释
> 可测试
> 再考虑微优化
~~~

### Go

- 避免过度抽象；
- 不为未来可能需求提前设计复杂 interface hierarchy；
- 小型命名 helper 优于深层匿名函数；
- error 必须带上下文；
- context lifecycle 明确；
- informer / reconciler 状态转换要可测试；
- 避免 reflection / metaprogramming；
- 不为“高级感”引入没必要的 generic abstraction。

### C / VPP plugin

- 仅在 plugin Goal 中出现；
- packet hot path 代码要直接、顺序清晰；
- pointer arithmetic、buffer access、next-node 选择必须有解释性 helper 或注释；
- 不做未经 benchmark 支持的微优化；
- ownership / buffer lifetime 必须明确。

---

## 10. 文档与注释语言

说明性内容默认中文：

- README；
- AGENTS；
- Goal；
- architecture；
- troubleshooting；
- Go/C/Shell 解释性注释。

identifier、API/type/function name、VPP/GoVPP 固有术语、command、log field、protocol name 保持英文。

例如 frame / vector / node / FIB / adjacency / DPO / CNAT / feature arc 无需强行翻译。

---

## 11. 测试原则

每个 Goal 至少要有与范围匹配的验证层级。

基础：

~~~text
gofmt
go test ./...
go vet ./...
~~~

如有 shell/python：

~~~text
bash -n
python3 -m py_compile
~~~

VPP/GoVPP Goal 不能只验证程序 exit code，至少检查：

- VPP process / API socket；
- GoVPP connection；
- API reply；
- VPP actual state；
- 必要的 packet E2E；
- cleanup。

Kubernetes Goal 至少检查：

- informer event；
- desired state；
- reconcile；
- VPP actual state；
- packet behavior；
- delete / restart / reconnect。

---

## 12. 失败路径

不要只写 happy path。随着项目推进，逐步覆盖：

- VPP 未启动；
- API socket 不存在；
- GoVPP disconnect；
- VPP restart；
- incompatible API；
- invalid desired state；
- Service 删除；
- Backend 删除；
- duplicate event；
- partial reconcile failure；
- Kubernetes watch reconnect。

失败时不允许悄悄产生“Go 认为成功但 VPP 实际失败”的永久分歧。

---

## 13. 性能与 benchmark

本项目重点先是 architecture correctness。

做 benchmark 时必须记录：

- VPP version；
- I/O backend；
- worker count；
- CPU / NUMA；
- packet size；
- flow count；
- offered load；
- RX/TX/drop；
- vector rate / node counters（可行时）；
- generator 类型；
- 是否经过 Linux kernel/TAP。

禁止把 TAP / AF_PACKET / Python generator 结果解释成 VPP line-rate 或 DPDK hardware performance。

---

## 14. Git 与提交

每个 Goal 应形成 focused commit。

建议格式：

~~~text
vpp: ...
govpp: ...
controller: ...
test: ...
docs: ...
~~~

禁止一次提交混入无关重构、格式化全仓库、依赖大升级、多个未验收 Goal、大日志 / pcap / binary / build output。

提交前：

~~~bash
git diff --check
git status --short
~~~

并检查 secrets、token、kubeconfig、证书和 host-specific 敏感数据。

---

## 15. Goal 文档要求

Goal 放在 `docs/goals/`。

每个 Goal 至少写清楚：

1. 背景；
2. 要学习的机制；
3. 要实现的功能；
4. 明确 non-goals；
5. 环境/版本；
6. 实现边界；
7. 验收命令；
8. 必须证明的运行证据；
9. Codex 实现记录；
10. ChatGPT 验收结论。

没有真实运行证据时，不允许把 Goal 标为完成。

---

## 16. 当前 5-Goal 演进路线（2026-10-09 生效）

> 早期九 Goal 计划已合并为五个较大 Goal。以本节和 README 为准；不允许根据历史 Goal 编号误判进度。

~~~text
Goal 001 ✅ 已完成并通过真实 VPP24.10 工程验收
  Runtime / GoVPP / TAP graph / L3 forwarding / trace
  （理论回讲约 75%～80%，还有少量首包/trace/cleanup 复盘）

Goal 002 ⬜ 未启动
  GoVPP Control Plane / FIB / Stats / CNAT Service
  VIP/backend/session/TCP/UDP/动态增删

Goal 003 ⬜ 未启动
  Go Service Model / Reconciler / Kubernetes Integration

Goal 004 ⬜ 未启动
  Two-Node Service Dataplane / Recovery / Observability

Goal 005 ⬜ 未启动
  Small Custom VPP Plugin / Finalization（计划完成，并非可选）
~~~

Goal001 现成的证据、代码与验收以 `docs/goals/001-vpp-govpp-environment-baseline.md` 和 `results/goal001/README.md` 为准。Goal002 不得在 Goal001 理论回讲收尾前被自动执行，且启动前必须匹配 VPP24.10 核对 GoVPP/CNAT API/schema。

---

## 17. 新对话权威接续状态（2026-10-09）

新对话请先按顺序阅读：

1. `docs/2026-10-09-goal001-vpp-runtime-dpo-concurrency-handoff.md`；
2. `README.md` 的当前 Goal 与五阶段路线；
3. `docs/goals/001-vpp-govpp-environment-baseline.md` 的最终验收段落；
4. `results/goal001/README.md`（真实 packet trace / counters / ARP / cleanup）；
5. 高性能学习仓库 `notes/2026/2026-10-09-vpp-runtime-dpo-concurrency-learning-handoff.md`。

本轮已理解：worker main-loop boundary、128-loop adaptive activity 双桶、RTC、DPO child/parent（LB child stack onto adjacency parent）、64-bit dpo_copy atomic、adjacency 对象 refcount=0 后 barrier 回收、adj rewrite 内容更新的 barrier 与 back-walk。此前部分笔记曾反转 DPO parent/child 或把 ip4-load-balance 当普通 trace 必经 node；以 matching-tag 源码和实际 Goal001 trace 为准。

继续顺序：**glean/ARP→resolved /32 adjacency（首包丢失）→正反向 UDP/trace/counters→cleanup 边界→Goal001 知识小结→设计 Goal002**。不要重讲已掌握的 DPO/barrier，也不要把尚未实施的 Goal002 写成已完成。

### 源码 / 证据边界

任何新的 VPP 机制结论仍需先读取 FD.io VPP 24.10 官方源码/文档；本次只是记录已核对的材料与学习位置，不替代重新核对。单 `vpp_main` 的 TAP software 实验不等于 multi-worker / hardware NIC 的性能或功能验证。

---

## 18. 正式资料优先与回答依据

本项目后续所有涉及 VPP / GoVPP / dataplane 机制、API 语义、版本行为、实现设计与验收结论的回答和代码决策，必须先核对正式资料，不允许仅凭聊天记忆、经验印象或二手博客下结论。

资料优先级：

1. 与当前项目版本匹配的 FD.io VPP 官方文档；
2. 与当前 VPP release/tag 匹配的 VPP 官方源码、源码注释、API JSON 与 CLI help/runtime 输出；
3. GoVPP 官方仓库、版本对应的 generated binapi、官方示例与文档；
4. 相关正式标准/RFC、Linux kernel 官方文档或上游源码；
5. 本项目在真实环境中采集并可复现的运行证据；
6. 社区文章、博客、问答只能作为补充线索，不能作为关键机制结论的唯一依据。

执行规则：

- ChatGPT / Codex / Agent 在解释 VPP 机制前，先查与当前版本相符的官方文档或官方源码；
- 涉及 parent/child、DPO、FIB、adjacency、feature arc、graph/node/frame、worker、CNAT、Binary API 等容易产生术语歧义的内容，必须以官方定义为准；
- 官方文档与源码存在版本差异时，以项目实际 VPP 版本对应源码和实际运行行为为最终依据，并明确说明版本；
- 官方资料与此前聊天中的 mental model 冲突时，必须直接指出并修正，不得为了维持前文一致而继续错误解释；
- 如果正式资料没有明确说明，必须标注为“推断 / 当前理解 / 待实验证实”，不能包装成官方结论；
- 回答中应尽量指出所依据的官方文档、源码文件/函数、API schema 或真实运行证据，保证结论可追溯；
- 不允许把未核对的博客、搜索摘要或模型记忆写成项目长期知识；
- 学习笔记中的关键结论同样需要记录其依据，尤其是纠正既有认知时。

当前 VPP 基线为 24.10 release 时，源码级机制解释默认优先核对对应的 VPP 24.10 tag/release，而不是直接引用 master 的实现行为。
