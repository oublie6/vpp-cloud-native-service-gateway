# 排障索引

1. **API 连接或 schema 失败**：检查 `/run/vpp-goal001/api.sock`、VPP pid 和 `show version`；Goal 005 的 GoVPP CLI 先做 `CheckCompatiblity`，失败时核对仓库 `.api`、构建生成的 JSON 与实际插件版本。不要盲目升级 VPP/GoVPP。
2. **feature 已启用但无 node 计数**：`show interface features tap101` 应在 `ip4-unicast` 下列出 `goal005-observe`。检查 input node 与 `show trace`；当前 TAP 实测 input 为 `virtio-input`。feature 只观察进入指定 RX interface 的 IPv4 packet。
3. **首个 ping 丢失**：查看 `show ip neighbors`、`show adj`、`show trace` 的 `ip4-glean` 与 ARP；本机实验首包因邻居未解析而丢失，后续完成 adjacency 后成功。不要将该现象直接解释为插件 drop。
4. **remote backend 超时**：按 Goal 004 证据检查 `/32` VPP API route、next-hop adjacency、namespace 路由和 EndpointSlice readiness。远端 veth down/up 后 Linux 曾删除 namespace 默认路由。
5. **VPP/controller 重启后缺 CNAT**：检查 `cmd/vpp-service-agent` 的 reconcile 指标、API socket 和 `cnat_translation_dump`；controller 会在 API 恢复后重新收敛。不能仅凭进程活着认定 actual state 正确。

插件复验：`scripts/goal005/test-plugin.sh`。它会临时重启独立 VPP、建立/清理 Goal 001 拓扑，并复查默认 route、管理 IPv4、namespace 和插件文件；请在无其他 Goal 001 拓扑实验时运行。
