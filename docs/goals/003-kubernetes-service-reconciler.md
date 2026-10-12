# Goal 003：Service Model / Reconciler / Kubernetes Integration

状态：Codex 已实现并通过真实 kind/VPP 验证；待 ChatGPT 学习 / 工程验收。

## 背景与机制

Goal 002 已在 VPP 24.10 上验证 GoVPP FIB/Stats/CNAT。Goal 003 将 Kubernetes Service 与 EndpointSlice 转成隔离 VIP 的 desired state，由幂等 reconciler 通过 GoVPP 驱动 VPP CNAT actual state。controller 必须能处理事件重复、乱序、删除、watch 重连和 VPP/GoVPP 断线后的重新收敛。

## 固定环境与安全边界

- Ubuntu 20.04、kernel 5.4.0-216-generic、Go 1.24.13、VPP 24.10-release、GoVPP v0.13.0，沿用 Goal 001/002 独立 runtime 和 TAP 软件拓扑。
- 本机开始时没有 `kubectl`、`kind`、`k3s`、kubeconfig 或运行中的 kubelet；Docker 26.1.3 可用。计划使用隔离 kind 测试集群，版本固定为 Kubernetes v1.33.1 / client-go v0.33.1 / kind v0.29.0。client-go v0.33.1 官方 `go.mod` 要求 Go 1.24.0，当前工具链满足。实际安装/运行前需记录 host 网络、路由、关键 sysctl 与 Docker 状态；若 kind 不可用，保留独立可验证的模型与 fake watch 测试，标记集成验收阻塞。
- 仅处理带项目 opt-in annotation、且 VIP 在 Goal 003 专用的 `198.19.0.0/16` 实验网段内的 Service；与 Goal 002 的 `198.18.0.10` 分离，不接管普通 ClusterIP，也不关闭或修改 kube-proxy。
- 不操作宿主管理 NIC、默认路由、VFIO、DPDK NIC。不把 Kubernetes callback 写成直接命令式 VPP 调用；所有变更经 desired-state store 与 reconcile。

## 计划与验收门槛

### Stage A：模型与幂等 reconcile

1. 定义 Service identity、协议/端口、隔离 VIP、backend endpoint 的归一化模型和确定性排序；拒绝不支持的协议、地址、端口、VIP 与空/冲突配置。
2. 建立 desired-state store 和 actual-state 查询；reconciler 计算 add/update/delete，在 API reply 后再次检查 VPP actual state，不把部分失败当成功。
3. 通过 fake VPP client 覆盖 duplicate event、事件乱序、backend add/delete、Service delete、部分失败重试与全量 resync。

门槛：测试证明重复 reconcile 不额外写入、乱序事件最终收敛、失败后可重试；实际 VPP 的 CNAT 状态检查入口明确。

### Stage B：Kubernetes watch 与 desired state

1. 使用 client-go informer/watch 监听 Service 和 EndpointSlice；仅选择 opt-in Service，并按 Service UID/name/namespace 与 EndpointSlice 标签关联。
2. informer callback 只更新 store/入队；worker 从缓存构建快照并 reconcile。处理 ready/terminating endpoint、地址族和端口匹配、删除事件与 watch 重连。
3. 在 fake client 与真实测试 API server 上验证 add/update/delete、EndpointSlice scale、重复事件、cache resync 和断开后的重新 list/watch。

门槛：Service/EndpointSlice 事件确实驱动 desired state；无用户手工 VPP CLI 配置；普通 Kubernetes Service 不被接管。

### Stage C：VPP 实际状态与恢复

1. 在 Goal 002 隔离拓扑和真实测试 API server 中，通过 Kubernetes 对象变更驱动 GoVPP CNAT update/delete，并完成 TCP/UDP packet E2E。
2. 验证 controller 重启、VPP 重启和 GoVPP reconnect 后重新收敛；观察 API reply、translation/session、trace/counter 与 cleanup。
3. 记录 Kubernetes/VPP/GoVPP/Go 版本、测试与故障路径；删除测试资源与 kind 集群，比对宿主 default route、管理接口和实验资源。

门槛：真实 watch→desired state→reconcile→GoVPP→VPP→packet 链路和恢复测试均有可复现证据；`go test ./...`、`go vet ./...`、shell/Python syntax、`git diff --check` 通过。缺任何关键证据则 Goal 003 保持未完成，不进入 Goal 004。

## Non-goals

本 Goal 不做双节点 remote backend、软件性能 benchmark 或自定义 VPP plugin；分别属于 Goal 004、005。

## Codex 实现记录

### Stage A：模型与幂等 reconcile

新增 `internal/service` desired-state model/store/reconciler，隔离 VIP 固定为 `198.19.0.0/16`。对每个 translation key 的后端排序去重、拒绝无效地址/端口和 ownership 冲突；重复快照不产生额外 VPP 写入。写入后重新读取 actual state，发现 API 假成功、部分失败或未收敛时返回错误，周期重试。`internal/vppcnat` 以 GoVPP Binary API 实现 CNAT dump/update/delete，每次连接先做运行时 CRC 兼容性检查。真实 VPP 上 add/duplicate/update/delete 输出的 changed 值为 `2/0/2/2`，每次均 `verified=true`。

### Stage B：Kubernetes watch 与 desired state

新增 `internal/kube`：Service 和 EndpointSlice informer callback 仅通知 worker；worker 从 cache 全量建立快照，更新 store，执行 reconcile。只有携带 `vpp-gateway.example/test-vip` annotation、VIP 在 Goal 003 隔离网段中的 Service 会被处理；拒绝与 ClusterIP、ExternalIP、LoadBalancerIP/ingress 冲突的 VIP。EndpointSlice 按 namespace、Service 名称/owner UID（存在时）、端口、协议关联，过滤未 ready、未 serving 或 terminating 的 endpoint。fake client 测试证明 add/update/delete 与重复事件收敛；真实 kind API server 上的两协议流量、缩容、扩容和 Service 删除均驱动 VPP actual state。

### Stage C：packet E2E、重启与 cleanup

沿用 Goal 001 TAP 与 Goal 002 CNAT plugin，在 Kubernetes v1.33.1/kind v0.29.0、VPP 24.10-release、GoVPP v0.13.0、Go 1.24.13 上完成 `Service/EndpointSlice -> informer -> desired store -> reconciler -> GoVPP -> VPP CNAT -> TCP/UDP packet`。20 条 UDP 流量分布 `.3/.2=11/9`、20 条 TCP 流量分布 `.2/.3=12/8`；EndpointSlice 缩容后 10 条新 UDP flow 全到 `.2`。真实 trace 含 `virtio-input -> ethernet-input -> ip4-input -> ip4-lookup -> ip4-cnat-tx -> ip4-load-balance -> ip4-rewrite -> tap102-output -> tap102-tx`。

controller 重启后全量 cache 同步无重复写；VPP 停止期间连接失败显式记录，重启后 TCP/UDP translation 与 packet 恢复；隔离 kind API server 重启后 watch 出现短暂连接错误，恢复后 EndpointSlice 扩容再次生效。删除 Service 后 VPP translation 删除。kind、Docker bridge、namespace、TAP、CNAT 清理完毕，测试前后 host state 精确 diff 为零。命令、counter、失败日志和 caveat 见 [Goal 003 实际证据](../../results/goal003/README.md)。

本 Goal 不包含双节点 remote backend、benchmark 或自定义 plugin；留待明确授权的后续 Goal。

## ChatGPT 学习 / 工程验收

待验收。

## 一手资料

- [client-go compatibility matrix](https://github.com/kubernetes/client-go#compatibility-matrix)
- [kind v0.29.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.29.0)
- [Kubernetes EndpointSlice 文档](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
