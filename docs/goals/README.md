# Goals

本目录保存项目各阶段 Goal、Codex 实现记录和 ChatGPT 验收结论。

当前状态：

~~~text
Repository bootstrap        ✅

Goal 001
VPP / GoVPP Environment Baseline
状态：🟡 已设计，待 Codex 实现与 ChatGPT 验收

当前 Goal：
`docs/goals/001-vpp-govpp-environment-baseline.md`
~~~

推荐路线：

~~~text
001  VPP + GoVPP environment baseline
002  graph / frame / node / worker + L3 forwarding
003  GoVPP interface / FIB / route / stats
004  CNAT / Service baseline
005  Go Service model + reconciler
006  Kubernetes Service / EndpointSlice
007  two-node local / remote backend
008  observability / benchmark / troubleshooting
009  small custom VPP plugin（可选）
~~~

每个 Goal 至少包含：

1. 背景与学习目标；
2. 环境和版本；
3. 实现范围；
4. 明确 non-goals；
5. 设计约束；
6. 验收命令；
7. 必须提供的运行证据；
8. Codex 实现记录；
9. ChatGPT 验收结论。

规则：

- Codex 只能执行当前明确指定的 Goal；
- 未经 ChatGPT 验收，不进入下一 Goal；
- 没有真实运行证据，不得把 Goal 标记为完成；
- 版本、API 和安装方式以当前官方文档及实际环境为准；
- software TAP/AF_PACKET 结果不得表述为真实 NIC / line-rate 性能。
