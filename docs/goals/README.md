# Goals

本目录保存项目各阶段 Goal、Codex 实现记录和 ChatGPT 验收结论。

当前状态：

~~~text
Repository bootstrap        ✅

Goal 001
VPP Runtime / GoVPP / Graph / L3 Forwarding
状态：✅ 已实现并通过 ChatGPT 验收

Goal 002：`docs/goals/002-govpp-control-plane-cnat-service.md`（🟡 Codex 已实现，待 ChatGPT 最终验收）

当前 Goal：
`docs/goals/003-kubernetes-service-reconciler.md`（🟡 Codex 已实现并通过 kind/VPP 实测，待 ChatGPT 最终验收）
~~~

项目采用 5 个较大的 Goal：

~~~text
001  VPP runtime + GoVPP + graph/node/frame/worker + L3 forwarding
002  GoVPP control plane + FIB/route/stats + CNAT Service
003  Go Service model + reconciler + Kubernetes Service/EndpointSlice
004  two-node dataplane + recovery + observability + benchmark
005  custom VPP plugin + custom Binary API + project finalization
~~~

五个 Goal 全部计划完成。

与原先较碎的 Goal 划分相比，现在强调：

- 减少 Goal 数量；
- 每个 Goal 内部分 Stage；
- Codex 不一次性把整个大 Goal 黑盒做完；
- 每完成一个关键 Stage，由 ChatGPT 结合代码、trace、counter 和源码进行机制讲解；
- 用户理解当前 Stage 后再继续下一 Stage；
- 工程实现必须服务于学习，而不是只追求“功能跑通”。

每个 Goal 至少包含：

1. 背景与学习目标；
2. Stage 划分；
3. 环境和版本；
4. 实现范围；
5. 明确 non-goals；
6. 设计约束；
7. 每个 Stage 的验收命令；
8. 必须提供的运行证据；
9. Codex 实现记录；
10. ChatGPT 学习/工程验收结论。

规则：

- Codex 只能执行当前明确指定的 Goal / Stage；
- 当前用户已授权连续完成 Goal 002～005；各 Goal 必须先满足对应验收条件，才能进入下一 Goal。
- 没有真实运行证据，不得把 Stage 或 Goal 标记为完成；
- 版本、API 和安装方式以当前官方文档及实际环境为准；
- software TAP/AF_PACKET 结果不得表述为真实 NIC / line-rate 性能；
- 不允许为了减少交互而一次性提前实现后续 Goal。
