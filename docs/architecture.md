# 架构与数据路径

## 控制面

Kubernetes Service 和 EndpointSlice 由 `internal/kube` 的 informer 收集。`internal/service` 将目标 Service/Backend 正规化并幂等 reconcile；`internal/vppcnat` 用 GoVPP Binary API 写入、核对 VPP 24.10 CNAT。`cmd/vpp-service-agent` 在 reconnect 后重新收敛，loopback `/metrics`、`/status` 提供控制面诊断。Go 不处理每个 packet。

## 数据面

Goal 001 的独立 VPP 实例通过 Linux TAP 连通两个 namespace。Goal 002～004 在同一 VPP 实例上验证 FIB/DPO/adjacency、CNAT VIP、local/remote backend；原实验的 remote 是单机隔离网络命名空间中的逻辑节点。补充实验经 SSH/TCP TUN 到现有美国 Kubernetes 节点，并以真实 Pod IP 作为远端 CNAT backend。Goal 005 的 `goal005-observe` 挂在 `ip4-unicast` feature arc，读取 IPv4 src/dst、RX interface、next index 并增加 info counter，buffer 原样交给 VPP 后继 node。它不参与 CNAT 选择，不改写 packet，也不接管 buffer 生命周期。

```text
Kubernetes Service/EndpointSlice -> informer -> desired state -> reconciler
    -> GoVPP Binary API -> VPP CNAT/FIB

client TAP -> virtio-input -> ethernet-input -> ip4-input
    -> goal005-observe（仅启用时）-> ip4-lookup -> CNAT/FIB/DPO
    -> adjacency/ip4-rewrite -> output TAP -> backend
```

Goal 005 自定义 API 仅控制单接口 feature 开关；正式 Service 控制仍通过 GoVPP CNAT/FIB。插件测试后卸载，常态 VPP 不加载该插件。

Goal 006 从固定 VPP 24.10 源码隔离构建候选插件，把 CNAT reverse session 放到 `CNAT_LOCATION_INPUT`，并在实验后端 TAP 启用 `cnat-input-ip4`。输入 feature 在普通 FIB lookup 前匹配 reverse session，使首个快速后端应答不依赖 main thread 异步安装 client /32 FIB 的完成时刻。用户授权后，Goal001 独立常驻 VPP 从 `/var/lib/vpp-goal006/plugins` 加载候选；系统发行版文件未改，可用 `scripts/goal006/deploy-cnat.sh rollback` 恢复。Goal002 Service 实验自动在后端 TAP 启用输入 feature；其他后端入口需要单独配置。来源、时序推断和测试范围见 [Goal006 证据](../results/goal006/README.md)。

## 约束

隔离 VIP 不与 kube-proxy 的普通 ClusterIP 争用。主要验证基于 VPP 24.10、TAP/Linux kernel；已有受控双 worker 功能复验，以及经 SSH/TCP TUN 的真实跨主机 Service packet E2E。2026-10-15 两个 Kubernetes 节点均为 `Ready`，补充实验已验证 VPP CNAT 到美国节点真实 Pod 的 TCP 正反向路径和 EndpointSlice readiness 收敛。Kubernetes SDK 已匹配 v1.36.4，Go1.26.9 由隔离工具链提供。公网 WireGuard UDP 仍故障；Cilium VXLAN UDP 位于 SSH/TCP TUN 内部。没有真实 NIC benchmark 结论。详细运行结果见 `results/goal001`～`results/goal006`。
