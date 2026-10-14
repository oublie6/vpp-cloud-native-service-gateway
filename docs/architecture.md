# 架构与数据路径

## 控制面

Kubernetes Service 和 EndpointSlice 由 `internal/kube` 的 informer 收集。`internal/service` 将目标 Service/Backend 正规化并幂等 reconcile；`internal/vppcnat` 用 GoVPP Binary API 写入、核对 VPP 24.10 CNAT。`cmd/vpp-service-agent` 在 reconnect 后重新收敛，loopback `/metrics`、`/status` 提供控制面诊断。Go 不处理每个 packet。

## 数据面

Goal 001 的独立 VPP 实例通过 Linux TAP 连通两个 namespace。Goal 002～004 在同一 VPP 实例上验证 FIB/DPO/adjacency、CNAT VIP、local/remote backend；remote 是单机隔离网络命名空间中的逻辑节点。Goal 005 的 `goal005-observe` 挂在 `ip4-unicast` feature arc，读取 IPv4 src/dst、RX interface、next index 并增加 info counter，buffer 原样交给 VPP 后继 node。它不参与 CNAT 选择，不改写 packet，也不接管 buffer 生命周期。

```text
Kubernetes Service/EndpointSlice -> informer -> desired state -> reconciler
    -> GoVPP Binary API -> VPP CNAT/FIB

client TAP -> virtio-input -> ethernet-input -> ip4-input
    -> goal005-observe（仅启用时）-> ip4-lookup -> CNAT/FIB/DPO
    -> adjacency/ip4-rewrite -> output TAP -> backend
```

Goal 005 自定义 API 仅控制单接口 feature 开关；正式 Service 控制仍通过 GoVPP CNAT/FIB。插件测试后卸载，常态 VPP 不加载该插件。

## 约束

隔离 VIP 不与 kube-proxy 的普通 ClusterIP 争用。主要验证基于 VPP 24.10、TAP/Linux kernel；已有受控双 worker 功能复验，但不作 benchmark 结论。现已识别两台物理主机，尚无成功的跨主机 packet E2E 或真实 NIC 性能证据。详细运行结果见 `results/goal001`～`results/goal005`。
