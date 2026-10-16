# Goals

本目录保存项目各阶段 Goal、Codex 实现记录和 ChatGPT 验收结论。

当前状态（2026-10-16：**v0.1.0 实验/学习版已封版**）：

~~~text
Goal001  ✅ 正式验收通过
Goal002  ✅ 代码/运行证据审查通过
Goal003  ✅ 代码/运行证据审查通过
Goal004  🟡 真实跨节点实验通过；特定 CNAT 多 worker 首包问题在 Goal006 下定向修复
Goal005  ✅ 功能审查通过；Goal006 已完成故障注入回滚加固
Goal006  ✅ ChatGPT 附条件验收：仅独立 VPP + IPv4 TAP + 显式 cnat-input-ip4
~~~

**没有当前待开发 Goal。** [封版记录](../RELEASE-v0.1.0.md)；[版本归档分支](https://github.com/oublie6/vpp-cloud-native-service-gateway/tree/release/v0.1.0)（不是 Git tag）；[Goal006 最终验收](006-cnat-multiworker-hardening-and-release.md)；[运行证据](../../results/goal006/README.md)。

以上“通过”均应结合各自证据及实验边界理解；不能误认为生产级兼容性或 ChatGPT 独立服务器复跑。

历史五个功能 Goal 主线（最终另加 Goal006 工程收尾）：

~~~text
001  VPP runtime + GoVPP + graph/node/frame/worker + L3 forwarding
002  GoVPP control plane + FIB/route/stats + CNAT Service
003  Go Service model + reconciler + Kubernetes Service/EndpointSlice
004  two-node dataplane + recovery + observability + benchmark
005  custom VPP plugin + custom Binary API + project finalization
~~~

原五个功能 Goal 与追加的 Goal006 已形成封版学习基线，不再自动扩展。

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
- Goal006 的 Stage A→D 已完成工程和附条件验收；历史执行授权不代表封版后可自行继续开发。
- 没有真实运行证据，不得把 Stage 或 Goal 标记为完成；
- 版本、API 和安装方式以当前官方文档及实际环境为准；
- software TAP/AF_PACKET 结果不得表述为真实 NIC / line-rate 性能；
- 不允许为了减少交互而一次性提前实现后续 Goal。
