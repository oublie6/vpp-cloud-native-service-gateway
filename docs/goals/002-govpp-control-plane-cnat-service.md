# Goal 002：GoVPP Control Plane / FIB / Stats / CNAT Service

状态：进行中；以下是实施计划和验收门槛，尚非运行结果。

## 背景与机制

在 Goal 001 已验收的 VPP 24.10 TAP/VIRTIO 拓扑上，将接口、FIB 和 Service 状态的正式控制边界移到 GoVPP Binary API。学习并验证 route/path、Stats API、CNAT translation、backend selection、session 与正反向改写的实际行为。Go 不处理逐包流量。

## 固定环境与边界

- Ubuntu 20.04 focal、kernel 5.4.0-216-generic；Go 1.24.13；VPP **24.10-release**；GoVPP v0.13.0。
- 复用 Goal 001 的独立 VPP runtime、TAP 和 namespace；使用隔离测试 VIP，不改宿主默认路由、管理 NIC、kube-proxy、VFIO 或 DPDK NIC。
- GoVPP v0.13.0 自带的 `cnat` binding 标明源 VPP **25.10-release**，不能直接假定与 24.10 兼容。先核对当前实例插件、24.10 API JSON 与 message CRC；必要时从本机 24.10 JSON 生成项目内 binding，并记录命令。不得靠随机升级依赖掩盖不兼容。
- 当前 `vpp` 包未安装 `vpp-plugin-core`，实例 `show plugins` 为空。需要先检查并仅安装与 VPP 严格同版的 `vpp-plugin-core=24.10-release`，记录 host state 与安装影响；不升级 VPP。

## 实施计划与验收条件

### Stage A：版本、schema 与实验边界

1. 记录安装前 HugePages、相关 sysctl、VPP/package 状态与宿主网络关键状态；模拟检查 APT 事务，确认不会升级现有 VPP。
2. 安装 24.10 同版 core plugin；验证 `cnat_plugin.so` 和 24.10 `cnat.api.json`、实际运行的 Binary API message/CRC；对照 GoVPP 生成 binding。核对 FIB、interface、Stats API 可用性。
3. 设计隔离 VIP、client、至少两个 backend 的可重复 setup/cleanup。清理后管理接口、默认路由及 Goal 创建资源恢复。

门槛：版本与 schema 有可追溯证据；GoVPP 发出的请求能收到正确 reply；没有以 25.10 binding 的编译成功代替 24.10 runtime 兼容性。

### Stage B：GoVPP FIB 与 Stats

1. 通过 GoVPP 配置/删除实验接口地址与路由；查询 VPP 实际 FIB，并验证 packet 转发。
2. 通过 GoVPP Stats API 读取至少接口 packet/error counter，记录流量前后值及其限制。
3. 覆盖重复 add/delete、无 VPP socket、错误参数和 cleanup。

门槛：API reply、VPP actual state、packet E2E、counter 差值与 cleanup 一致；`go test ./...`、`go vet ./...`、shell syntax、`git diff --check` 全部通过。

### Stage C：CNAT Service

1. 用 GoVPP 配置 IPv4 TCP/UDP VIP 与至少两个 backend；验证实际 translation、backend 选择、会话状态及同 flow affinity，记录该版本支持的 LB 模式。
2. 验证 client→VIP→backend 与 backend→client 的请求和应答，包括 L3/L4 地址端口、trace/counter。
3. 动态新增/删除 backend、删除 Service、验证已有和新 session 的实际行为，并重复 setup/cleanup。

门槛：至少两个 backend 收到真实流量；TCP/UDP 正反向成功；动态变更后 VPP 状态和新流量符合预期；会话、trace、counter、失败排障和资源清理均有真实证据。不能满足时保持本 Goal 未完成，不进入 Goal 003。

## Non-goals

本 Goal 不实现 Kubernetes watcher、desired-state reconciler、双节点性能测试或自定义 VPP plugin；分别留给 Goal 003～005。

## Codex 实现记录

- Stage A：`6c494aa`。安装同版 core plugin，核对 CNAT/interface/FIB message CRC，并在当前实例用 GoVPP Binary API 和 Stats API 真实读取。证据见 `results/goal002/README.md`。
- Stage B：GoVPP 写入/删除实验接口地址与 FIB route；实际 ICMP 3/3、删路由后 0/2、Stats RX/TX 增长、重复调用与 cleanup 成功。提交 SHA 待 Stage B focused commit 后填写。Stage C 尚未开始。

## ChatGPT 学习 / 工程验收

待验收。
