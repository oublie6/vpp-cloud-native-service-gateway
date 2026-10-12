# Goal 005：小型 VPP 观测插件与项目收尾

状态：Codex 已实现并在 VPP 24.10 实测；ChatGPT 学习 / 工程验收待验收。

## 背景与机制

Goal 001～004 已在 VPP 24.10 软件 TAP 环境验证 graph、FIB、CNAT、GoVPP 和 Kubernetes reconcile。本 Goal 用一个最小 IPv4 feature node 验证 VPP plugin 注册、frame/buffer 遍历、next node、trace、计数和自定义 Binary API；GoVPP 作为正式控制边界。

## 环境与边界

Ubuntu 20.04、kernel 5.4.0-216-generic、VPP/vpp-dev 24.10-release、GoVPP v0.13.0、Go 1.24.13。复用 Goal 001 TAP 拓扑和独立 VPP 实例。不升级 VPP、不碰管理 NIC、默认 route、kube-proxy、DPDK/VFIO；不重写 FIB、ARP、CNAT 或做 throughput benchmark。

## 实现与验收门槛

1. `goal005-observe` 在 `ip4-unicast` arc 按接口启用；只读取 IPv4 头，保留 buffer 所有权并交给 feature arc 的 next node。记录 node trace 与 packet counter。
2. 使用 VPP 24.10 `vppapigen` 从仓库 `.api` 生成 JSON/C，再用 GoVPP v0.13.0 生成 Go binding。GoVPP enable/disable 必须收到成功 reply；错误 interface 必须失败。
3. 真正重启独立 VPP 并加载插件，在 TAP L3 E2E 中采集开启前后 node、feature、trace、counter、ping/UDP、错误计数；关闭后流量仍通且 node 不再被调用。
4. 构建产物置于 `/tmp`，测试时仅暂装到独立 VPP 的 plugin 搜索目录；先记录 host/package/VPP 状态，cleanup 后移除本 Goal 插件并复查 host 默认 route、管理接口和实验资源。
5. 完成架构、排障、软件测量边界与最终项目总结；`go test ./...`、`go vet ./...`、`bash -n`、`git diff --check` 通过。

## Codex 实现记录

插件的 `goal005-observe` VLIB node 注册于 `ip4-unicast`，逐个遍历 frame 的 buffer，读取 IPv4 src/dst 和 RX interface，用 `vnet_feature_next` 将原 buffer 交给真实后继 node；注册 trace formatter 与 info 计数。自定义 `goal005_observe_enable_disable` API 按 `sw_if_index` 控制 feature，GoVPP v0.13.0 generated binding 和 CLI 做 schema 检查及 reply 校验。构建用与运行实例匹配的 VPP 24.10 头文件、`vppapigen` 和本机 CMake/Ninja。

临时装载插件并重启 Goal 001 独立 VPP 后，GoVPP enable 返回 0，`show interface features tap101` 显示 feature。真实 ICMP/UDP E2E 成功；trace 中 `virtio-input -> ethernet-input -> ip4-input -> goal005-observe -> ip4-lookup -> ip4-rewrite -> tap102-output`，观察计数为 4、runtime Calls/Vectors 为 4/4。disable 后 ICMP 2/2 成功，计数不再增长。脚本自动删除 TAP/namespace/plugin 并恢复不加载插件的独立 VPP；宿主默认 route、管理 IPv4、原 namespace 不变。实际输出和排障见 [Goal 005 证据](../../results/goal005/README.md)。

## ChatGPT 学习 / 工程验收

待验收。

## 一手资料

- [FD.io VPP 24.10 sample plugin](https://github.com/FDio/vpp/tree/stable/2410/src/examples/sample-plugin/sample)
- [FD.io VPP 24.10 feature API](https://github.com/FDio/vpp/blob/stable/2410/src/vnet/feature/feature.h)
- [GoVPP v0.13.0 binapi generator](https://github.com/FDio/govpp/tree/v0.13.0/cmd/binapi-generator)
