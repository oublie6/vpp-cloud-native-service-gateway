# Goal 006：CNAT 多 Worker 首包修复 / Plugin 回滚 / Kubernetes 兼容 / CI 收尾

状态：🟡 **Stage B～D DONE；Stage A BLOCKED（隔离候选补丁通过，常驻插件切换待单独授权）；ChatGPT 未验收。**
优先级：P0（Stage A）→ P1（Stage B）→ P2（Stage C、D）。本 Goal 是 Goal002～005 的遗留问题收尾，不新增替代 CNI、通用 NAT、Web 管理系统等功能。

## 1. 背景与权威证据

本项目在 VPP 24.10、GoVPP v0.13.0、Linux TAP、Kubernetes kind/双主机软件链路上完成 Goal001～005 的主要功能。参见 results/goal002～005/README.md，重点阅读 results/goal004/README.md 的“VPP 双 worker 的 Service 功能复验”：
- 两个 VPP worker、无人工后端响应延迟的首次 UDP 回包曾暴露非 VIP 源地址，说明逆向改写未按预期生效。
- 在测试服务增加 200 ms 延迟后 TCP/UDP 测试成功；**延迟不是修复**。
- “CNAT 的异步 main-thread 学习与首次回包竞争”只是基于当时现象和源码的假设，未证明为唯一根因。
- Goal005 的 scripts/goal005/test-plugin.sh 在 stop-vpp 成功、install 失败的窗口内，owned 仍为 0，可能漏恢复原 VPP。
- 当前仓库 client-go/api/apimachinery v0.33.1；真实集群为 Kubernetes v1.36.4，旧 kind 测试集群为 v1.33.1；客户端版本对应与 Go 工具链要求需要官方核验。
- 当前没有仓库级 GitHub Actions 静态回归。

必须先阅读 AGENTS.md、README.md、docs/architecture.md、docs/goals/004...、docs/goals/005... 和上述原始证据。VPP 机制结论严格以 FD.io VPP 24.10 matching-tag 官方源码/API/schema 与本机实测为准；GoVPP/Kubernetes 以官方同版源码为准。不得将推测写成确认的根因。

## 2. 环境与保护边界

- 默认保持 VPP 24.10-release、GoVPP v0.13.0、当前 CLI/Binary API 和 CNAT schema；不得为“解决问题”盲目升级 VPP/GoVPP。
- 对多 worker 和 plugin 的所有破坏性试验，只能在经过 ownership 检查的独立 VPP/TAP/network namespace 环境进行。启动前检查宿主网络、默认路由、管理网卡、VPP/进程、实验资源、已有 Kubernetes/SSH TCP tunnel 及相关服务状态；停止或重启独立 VPP 前必须确认没有其他任务依赖。
- 不修改宿主默认路由、管理 NIC、全局 firewall、kube-proxy、Cilium、现有 kubelet/真实集群对象、运行中的 SSH/TCP node tunnel、WireGuard、VFIO/DPDK 设备。需要这些变更时暂停并报告，等待单独授权。
- 仅清理本 Goal 创建并持有明确 ownership marker 的资源，不执行无边界的 CNAT session purge、不覆盖未知路由或系统已有插件。
- 不将 SSH/TCP TUN 的功能结果表述为原生公网 UDP、生产网络吞吐或硬件 line-rate。
- 源码、运行证据、注释、文档中文；禁止提交 kubeconfig、SSH 凭据、tokens、宿主敏感配置、完整大日志与 pcap。

## 3. Stage A（P0）：双 worker 首个 UDP 回包错误的根因与修复

### A1：建立稳定失败复现，不允许掩盖

1. 以 scripts/goal004/test-multiworker.sh、scripts/goal002/test-service.sh 为基础新增隔离的零人为延迟回归入口；初始尽可能保持原始行为，保留失败的真实证据。
2. 记录 VPP 进程、版本、worker 数、tap101/tap102 RX queue → worker placement、VIP、backend、5 元组和每个 flow 的首次响应 peer，分别对照：单 main/单 worker；双 worker 分离 RX；双 worker 同一 RX worker。新建 flow 每轮都应使用全新源端口。
3. 准确采集请求/应答两侧 trace、CNAT translation/session dump、FIB/DPO/adjacency、错误计数，必要时对**实验 TAP**用 tcpdump；记录是否出现“已收到后端回应但客户端 peer 不等于 VIP”。
4. 对照 VPP 24.10 官方 src/plugins/cnat 的 session 创建、反向匹配/FIB 注册、worker→main thread RPC 与节点执行路径，建立带源码位置和先后时序的因果链。可用受控延迟 0/小值/200ms 做**定位对照**，但不得将延迟本身作为完成条件。

### A2：消除缺陷并回归

1. 优先找 VPP 24.10 官方已有的正确配置/线程所有权/初始化顺序；若必须修 CNAT 源码，应形成**可复现的 24.10 源码 patch、独立构建和受控加载方案**，禁止直接手工改系统二进制或覆盖未知插件。标注补丁与官方代码差异、对象生命周期、并发同步及回退办法；修改 VPP 安装/全局系统状态须先停下取得额外授权。
2. 不得通过在 backend 人为 sleep、跳过首包校验、重试掩盖错误、延长客户端 timeout 或强制单 worker 作为“修复”。
3. 验收：双 worker、分离 RX 队列、**0 额外 backend sleep** 条件下至少 3 轮、每轮至少 100 个全新 UDP flow，所有首次回包都必须由客户端观察为 VIP:port；多 backend、正反向 trace 与 session 状态一致。再覆盖相同 worker placement、单 main 基线、TCP、backend add/delete、Service delete、VPP restart/reconnect；清理后恢复原 worker/拓扑。记录真实每轮成功/失败计数和测试上下文。此样本是功能回归，不构成“所有并发时序永不失败”的数学保证。
4. 如根因需要上游修复且当前受控环境无法安全解决，保留最小复现与源码结论，Stage A 标记 **BLOCKED/未完成**；不得宣称 Goal006 通过。

## 4. Stage B（P1）：Goal005 插件生命周期及失败注入

1. 修复 scripts/goal005/test-plugin.sh 在 stop-vpp、install、start-vpp、enable/disable、E2E、cleanup 任一阶段失败时的资源恢复。使用明确状态机/ownership：是否停止原 VPP、是否由本 Goal 成功安装 .so、是否成功启动目标实例，不以单个 owned flag 代表所有阶段。
2. 构建失败不应触碰原 VPP；stop 成功而 install 失败必须尝试恢复原 VPP；插件临时文件只能删除确认为本 Goal 安装的文件；预存同名插件时拒绝覆盖；恢复失败必须非零退出并保留可诊断信息。
3. 实施可逆、安全的**受控失败注入**，至少覆盖 install 失败、start-vpp 失败和 API enable 失败；核验进程、plugin、TAP/namespace、默认 route、管理接口、原工作状态，重复运行确保幂等。不得通过关闭 SSH 服务或改管理网络制造失败。
4. 正常回归：插件 node/feature 自定义 API、trace/counter、disable 后不再调用、Goal001 ICMP/UDP 不回退。

## 5. Stage C（P2）：Kubernetes 版本与 SDK 兼容性

1. 记录实际 Kubernetes API Server v1.36.4、kind v1.33.1、当前 Go/GoVPP 和 k8s.io/client-go/api/apimachinery 版本。阅读官方 client-go compatibility matrix、对应 tag 的 go.mod、Kubernetes API compatibility。
2. 根据实际 API 与 Go 工具链约束，选择与真实 v1.36.4 集群匹配且能构建的同一 minor 的三个 Kubernetes modules；优先评估 v0.36.x **实际存在的同版补丁 tag**，严禁直接 go get @latest、使用 master 或混用 k8s.io 不同 minor 版本。若需要更新 Go，尽量用隔离工具链；不得擅自修改宿主全局 Go、kubelet 或 Kubernetes 集群。
3. 变更前后执行全部 Go unit/fake-client/reconciler 测试及 real API Server watch/list、Service/EndpointSlice add/update/delete、重连、实际 GoVPP/VPP CNAT 回归。可保留 kind v1.33.1 的兼容性测试，但要清楚区分两个 server 版本。
4. 如果升级受官方最低 Go 版本或运行环境阻塞，提交可核验的版本矩阵与阻塞说明，不得伪称完成；不得为解决 SDK 差异升级 VPP。

## 6. Stage D（P2）：CI、回归与证据归档

1. 新增最小 GitHub Actions CI：PR/push 执行 Go format check、go test ./...、go vet ./...、bash -n、Python py_compile；Go 环境版本跟随已验证的 go.mod/toolchain，固定合理版本和权限。不得将需要 root、VPP、SSH 凭据或真实集群的 E2E 塞到 GitHub-hosted runner。
2. 把 Stage A/B 的隔离环境测试做成可重跑命令，允许本地手动运行；失败注入测试默认不触发破坏性行为。添加静态/功能/真实环境的分层测试说明。
3. 全量复验 Goal001～005 中受影响的回归，尤其是 Goal002 TCP/UDP CNAT、Goal003 Controller reconcile、Goal004 多 worker/跨节点 Pod TCP（仅有环境且隔离安全时）以及 Goal005 plugin；记录测试条件、run count、退出码、关键 trace/counter/cleanup。
4. 新建 results/goal006/README.md，逐 Stage 记录命令、环境版本、证据摘要、失败及剩余限制，并更新 README.md、AGENTS.md、docs/goals/README.md、docs/architecture.md、docs/troubleshooting.md 中的进度和限制。只有完全达标后才将 Goal006 标记待 ChatGPT 最终验收；不得自称 ChatGPT 已验收。
5. 各 Stage 用 focused commits，禁止 force push、reset --hard、覆盖用户本地修改；每次执行先按 AGENTS.md 完成 status/fetch/fast-forward pull。

## 7. 最终交付与验收门槛

- [ ] Stage A 零人为延迟首包复现、根因源码证据、真正修复；3×100 首次 UDP 回包正确且跨 worker / 正反向 TCP/UDP 回归完成。
- [x] Stage B 三类失败注入均验证原 VPP/网络状态恢复，插件正常启停/trace/GoVPP 无回退。
- [x] Stage C 版本矩阵、同 minor SDK/toolchain 兼容决策和真实 API server / VPP 回归均有证据；实验 Controller 的真实 API watch TCP 连接断开/恢复也已验证。
- [x] Stage D CI 静态检查本机通过，Goal001～005 的受影响回归和 host cleanup 通过；远端 GitHub Actions 结果待观察。
- [ ] 所有结论均区分 official source / 真实运行 / 推断；results/goal006/README.md 完整可复现。
- [ ] Codex 实现记录齐全；**ChatGPT 学习/工程验收结论单独待审**。

## 8. Non-goals

不做新的 CNI/Service Mesh/L7 产品，不修复与本项目无直接因果关系的公网 WireGuard UDP 上游路径，不宣称硬件性能；不借此机会重写 CNAT、全部 CI/CD 基础设施或升级 Kubernetes 集群版本。

## 9. 必须参照的权威资料

- FD.io VPP 24.10 CNAT 官方文档：https://docs.fd.io/vpp/24.10/developer/plugins/cnat.html
- FD.io VPP 24.10 matching-tag 官方源码：https://github.com/FDio/vpp/tree/stable/2410/src/plugins/cnat
- Kubernetes client-go 官方兼容矩阵：https://github.com/kubernetes/client-go#compatibility-matrix
- Kubernetes Service/EndpointSlice 官方文档：https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/

## 10. Codex 实现记录

| Stage | Codex 状态 | focused commit | 结果 |
|---|---|---|---|
| A | BLOCKED（常驻部署待授权） | `4e02181`、`55a12bf` | 原版双 worker 零延迟首包失败复现；固定 VPP v24.10 源码的最小 patch，独立构建与输入 feature，分离 RX 两次 3×100 首包均正确，重启恢复通过；常驻发行版 CNAT 未修改 |
| B | DONE | `0e3f94c` | build/install/start/API enable/traffic 注入与正常插件 E2E，两次完整回滚测试通过 |
| C | DONE | `c6272df`、`18563bd` | 三个 Kubernetes module 同步至 v0.36.4，隔离 Go1.26.9，真实 v1.36.4 双节点 API/Pod TCP、watch 连接中断/恢复与 Controller 重启通过 |
| D | DONE | `d9bad08` | CI 配置、本机静态检查、Goal001～005 受影响回归与 cleanup；GitHub Actions run 38701599580 全部 step 通过 |

完整命令、失败过程、来源边界和清理证据见 [results/goal006/README.md](../../results/goal006/README.md)。不将隔离补丁的成功等同于常驻实例已经修复。切换系统插件前须按第 2、3 节与 AGENTS.md 第 19 节另行取得授权。

## 11. ChatGPT 学习 / 工程验收结论

待验收。
