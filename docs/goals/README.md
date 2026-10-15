# Goals

本目录保存项目各阶段 Goal、Codex 实现记录和 ChatGPT 验收结论。

当前状态（2026-10-15，以最新仓库为准）：

~~~text
Repository bootstrap        ✅
Goal 001  ✅ 已通过最终验收
Goal 002  ✅ 已实现并有真实 VPP 证据；ChatGPT 代码/证据审查通过
Goal 003  ✅ 已实现并有 kind/VPP 证据；ChatGPT 代码/证据审查通过
Goal 004  🟡 已实现并有真实远端 Pod TCP E2E；多 worker UDP 首包缺陷仍未解决，附条件通过
Goal 005  ✅ 功能审查通过；异常安装回滚待加固
Goal 006  🟡 A～D 已实现并复验；ChatGPT 待验收
~~~

当前 Goal 文档：[006-cnat-multiworker-hardening-and-release.md](006-cnat-multiworker-hardening-and-release.md)。
说明：Goal002～005 的“代码与已记录证据审查”不等于本轮新做了服务器独立复跑；各旧 Goal 正式文档仍可能有历史的“待验收”文本。Goal006 的受控常驻候选加载、实际复验和适用限制见 [results/goal006](../../results/goal006/README.md)。

项目采用 5 个较大的 Goal：

~~~text
001  VPP runtime + GoVPP + graph/node/frame/worker + L3 forwarding
002  GoVPP control plane + FIB/route/stats + CNAT Service
003  Go Service model + reconciler + Kubernetes Service/EndpointSlice
004  two-node dataplane + recovery + observability + benchmark
005  custom VPP plugin + custom Binary API + project finalization
~~~

原五个功能 Goal 均已有实现；现在追加 Goal006 专门消除遗留稳定性缺陷和完成工程收尾，不把它当作新的产品功能。

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
- 当前用户已明确授权 Goal006，按其 Stage A→D 执行；每个 Stage 的证据不足时必须明确阻塞，不得以延迟/跳过测试伪称修复。
- 没有真实运行证据，不得把 Stage 或 Goal 标记为完成；
- 版本、API 和安装方式以当前官方文档及实际环境为准；
- software TAP/AF_PACKET 结果不得表述为真实 NIC / line-rate 性能；
- 不允许为了减少交互而一次性提前实现后续 Goal。
