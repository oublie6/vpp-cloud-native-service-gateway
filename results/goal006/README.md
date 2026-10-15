# Goal 006 运行证据（2026-10-15）

环境：Ubuntu 20.04 / kernel 5.15.0-139、VPP 24.10-release、GoVPP v0.13.0。实验使用 Goal001 的 Linux TAP 与 namespace；`tap101` 接 `ns-client` 10.10.1.2，`tap102` 接 `ns-server` 10.10.2.2；VIP 为 198.18.0.10:18080，两个 UDP backend 是 10.10.2.2/.3:18080。默认路由、管理接口以及两个真实 Kubernetes 节点不属于实验资源。

大型日志、pcap、core 和宿主快照只保存在本机 root 可读目录 `/root/goal006-evidence/`，不提交仓库。下面保留可复跑命令和关键观测；本机路径不构成跨机器共享证据。

## Stage A：CNAT 多 worker 首个 UDP 回包

状态：**DONE（候选修复已在独立常驻 VPP 加载并回归；ChatGPT 待验收）**。用户单独授权了常驻切换。系统发行版 CNAT 文件保持原样；Goal001 独立 VPP 通过专用插件搜索路径加载经过隔离验证的候选文件。

### 原始失败与机制依据

原始发行版 CNAT、`tap101 → vpp_wk_0`、`tap102 → vpp_wk_1`、后端零人为延迟时，首个 UDP 应答的客户端 peer 为 `10.10.2.3:18080` 而不是 `198.18.0.10:18080`；两次复现。客户端请求的 trace 有 `ip4-cnat-tx created session`，后端应答从 `virtio-input → ethernet-input → ip4-input → ip4-lookup → ip4-rewrite → tap101-output`，缺少 `ip4-cnat-tx`。后端日志证实收到请求。失败后的 API dump 已显示 CNAT sessions=2、客户端 /32 `cnat-client` interpose，说明该 FIB 项在采集时已经创建，不能把它误记为从未创建。对应原始日志是 `multiworker-zero-delay-original.log`、`multiworker-first-reply-diagnostic.log` 和 `first-reply/`。

官方 VPP v24.10 对应提交 `cfa0953251cbab435307baf3dcd249fd95afaf1f`：[`cnat_node_vip.c`](https://github.com/FDio/vpp/blob/cfa0953251cbab435307baf3dcd249fd95afaf1f/src/plugins/cnat/cnat_node_vip.c) 为 VIP 流创建 FIB 位置的 reverse session；[`cnat_node.h`](https://github.com/FDio/vpp/blob/cfa0953251cbab435307baf3dcd249fd95afaf1f/src/plugins/cnat/cnat_node.h) 的 `cnat_rsession_create` 先写 reverse hash，遇到未学习客户端再异步 RPC 到 main thread；[`cnat_client.c`](https://github.com/FDio/vpp/blob/cfa0953251cbab435307baf3dcd249fd95afaf1f/src/plugins/cnat/cnat_client.c) 的 `cnat_client_learn` 安装 client FIB；[`cnat_node_feature.c`](https://github.com/FDio/vpp/blob/cfa0953251cbab435307baf3dcd249fd95afaf1f/src/plugins/cnat/cnat_node_feature.c) 提供 `ip4-unicast` 输入 feature。由源码顺序和失败 trace 推断：首个后端应答可早于 main thread 安装 client FIB，到普通 FIB 转发而错过逆向 CNAT。这个实验支持该竞争解释，尚未证明不存在其他竞争。

### 最小候选修复与复验

`patches/goal006-cnat-return-input.patch` 将 reverse session 的查找位置从 `CNAT_LOCATION_FIB` 调整为 `CNAT_LOCATION_INPUT`；`cmd/goal006-feature` 用 GoVPP 在 `tap102` 的 `ip4-unicast` arc 启用 `cnat-input-ip4`。这样已创建的 reverse session 在 FIB 查找前可匹配，不等待异步 client FIB 学习。`scripts/goal006/build-cnat-patch.sh` 下载固定提交并校验源码 SHA256，仅在 `/tmp/goal006-cnat.*` 构建；未覆盖 `/usr/lib` 中的插件。

复跑命令（需 root、独立 VPP 空闲并通过脚本的 ownership 检查）：

```bash
scripts/goal006/build-cnat-patch.sh
GOAL006_PLUGIN_PATH=/tmp/goal006-cnat.<本次构建>/build/vpp_plugins \
  GOAL006_REQUIRE_AUTO_RX=true \
  GOAL006_ENABLE_INPUT_FEATURE=true GOAL006_FIRST_REPLY_REGRESSION=true \
  GOAL004_REPLY_DELAY=0 scripts/goal004/test-multiworker.sh
```

原始分离 RX 的干净构建实测 3 轮 × 100 个全新 UDP flow，逐个校验首次 peer，三轮分别 **100/100、100/100、100/100**。reverse trace 显示 `ip4-cnat-tx found session`、源改写为 VIP，session dump 的 reverse 项标为 `input`。同 worker RX 3×100 和发行版单 main 3×100 也全通过；TCP、双 backend、backend 增删、Service 删除与 API dump 均通过。隔离 VPP 重启后重新启用 feature、重连 GoVPP，再跑两次完整 3×100，重启前后均为每轮 100/100，最后恢复原单 main VPP。日志：`multiworker-clean-build-3x100.log`、`multiworker-same-rx-3x100.log`、`single-main-stock-3x100.log`、`multiworker-restart-regression-2.log`。

排障过程：首次重启回归在重复设置已正确的 TAP RX placement 时触发 VPP worker barrier abort；core 栈位于 `set_hw_interface_rx_placement`，而非 CNAT。后续精确 patch 重新构建时又遇到同样的隔离 VPP abort。查明 `show interface rx-placement` 的线程行以 `\r` 结尾，脚本的 `awk` 没有去除它，误判已经自动分离的 `tap101 → vpp_wk_0`、`tap102 → vpp_wk_1` 为不匹配，于是多余地调用 RX placement CLI。修正解析，并在 `GOAL006_REQUIRE_AUTO_RX=true` 时只核对自动分配、绝不动态迁移。最终源码重新构建的候选插件在该模式下，VPP 重启前后各 3×100 首次 UDP peer 均为 VIP，TCP/双 backend/Service 删除再次通过；日志 `build-repro-after-exact-patch.log`、`multiworker-auto-rx-final.log`。异常测试后原 VPP、namespace、默认 route 与管理接口均恢复。抓取 TAP pcap 的原版复现实验因采集开销没有重现错误，该 pcap **只证明成功流量**，不能充作失败包证据。失败证据以上述无 pcap 的 trace 和客户端 peer 为准。

补丁改变 reverse session 的 lookup 位置，并在接收后端报文的接口启用输入 feature；生命周期仍由 VPP 原有 CNAT session 机制管理。候选插件已用于 Goal001 独立常驻实例，系统发行版文件未覆盖；本节只证明所列功能回归，不是并发正确性的形式证明。

### 用户授权后的常驻部署、回退与重新部署

部署入口 `scripts/goal006/deploy-cnat.sh install <candidate.so>` 要求 root、原版/候选文件 hash 匹配、独立 VPP 只有 `local0`、无现存 namespace/TAP/CNAT session 或其他 CLI/API 客户端，并在停机前记录默认 route、管理接口、节点连接服务及 VPP 状态。`scripts/goal001/render-startup-config.sh` 根据 `/var/lib/vpp-goal006/active.sha256` 将专用 `/var/lib/vpp-goal006/plugins` 加入独立实例配置；校验失败时拒绝启动。原版插件 root-only 备份放在 `/var/lib/vpp-goal006/original-cnat_plugin.so`，不修改 `/usr/lib/x86_64-linux-gnu/vpp_plugins/cnat_plugin.so`。rollback 命令移除 active marker 并重新启动原版实例。

```bash
scripts/goal006/deploy-cnat.sh install /tmp/goal006-cnat.<本次构建>/build/vpp_plugins/cnat_plugin.so
scripts/goal006/deploy-cnat.sh rollback
scripts/goal006/deploy-cnat.sh install /tmp/goal006-cnat.<本次构建>/build/vpp_plugins/cnat_plugin.so
scripts/goal002/test-service.sh
```

本机执行先部署、rollback、再部署全部 exit 0；最终保持候选激活。每次 install 内均使用 `GOAL006_REQUIRE_AUTO_RX=true`、两个 worker 自动分离 RX、`GOAL004_REPLY_DELAY=0`，重启前后各做 3×100 新 UDP flow，六轮每轮客户端首次 peer 均为 VIP（100/100），TCP、双 backend、Service 删除及 GoVPP reconnect 通过。最终 `/proc/<VPP_PID>/maps` 指向专用目录 CNAT，active marker/候选 SHA256 均为 `d532c86af0805f0150ea9c5fa6b9cf81cec596fe13d4c941ea2e700f8816621b`；发行版文件 SHA256 仍为 `fb00daba9badf8052499f2918b1fb03757bf939cab36bb61e94e763ec5ad0ffe`。rollback 时 maps 指向发行版文件，API 基线 `interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0`，随后重新 install 再次通过。日志在本机 `/root/goal006-evidence/persistent-deploy.log`、`persistent-rollback.log`、`persistent-reinstall.log`，每次 600-flow 细节在 `/var/lib/vpp-goal006/deployment-e2e.log`。

切换后再次只读核对：`ip netns list` 为空，VPP 只有 `local0`；宿主默认 route 仍为 `via 10.0.138.1 dev eth0`，管理地址仍为 `10.0.138.51/24`；`goal004-worker-tcp-link`、kubelet、containerd 均 active。此主机未配置默认 kubectl context，直接运行 `kubectl get nodes` 报 resource NotFound；通过原有 SSH/TCP 连接在美国控制面节点使用其 `/etc/kubernetes/admin.conf` 只读查询，两现有节点 `hk-worker` 和 `ser730417996259` 均为 `Ready`。未更改 kubeconfig 或集群对象。

持久候选需要在接收 backend 响应的 VPP 接口启用 `cnat-input-ip4`。Goal002 Service 实验在发现 active marker 时自动通过 GoVPP 对 `tap102` 启用该 feature，cleanup 时关闭。默认 `scripts/goal002/test-service.sh` 再次 exit 0：TCP/UDP、双 backend、删除后流量失败均符合预期；测试中 VPP API 显示 2 translations、148 sessions，结束后 0 translations/0 sessions、仅 `local0`，TAP/namespace 消失。此默认调用在单 main 实例上运行；双 worker 零延迟证据来自上述每次 install 的 E2E。对其他接收 backend 响应的接口，仍需显式配置该 feature，不能将仅加载插件视为自动修复所有流量。

## Stage B：Goal005 插件异常回滚

状态：**DONE（本机两次完整通过）**。`scripts/goal005/test-plugin.sh` 在构建完成后才停原实例，分别跟踪原 VPP 是否已停止、候选插件是否由脚本安装、目标 VPP 是否启动、拓扑是否创建。插件采用唯一临时文件并通过无覆盖 hard link 安装；若目标路径预存同名 `.so`，安装前拒绝覆盖。清理仅删除自身安装的文件和有 ownership marker 的 TAP/namespace，并检查原实例 CLI/API socket、插件缺席、默认路由和管理接口。

```bash
sudo scripts/goal006/test-plugin-rollback.sh
```

脚本依次注入 `build`、`install`、`start`、`api-enable`、`traffic` 失败，再跑正常路径。两次运行均显示所有阶段后 VPP process/socket 恢复，Goal005 plugin 不残留，Goal001 TAP/namespace 清除，host route/管理接口和双节点相关服务正常。`build` 失败时原 VPP PID 保持不变；其他注入中原实例重新启动，PID 会变化。正常路径还验证插件 API enable/disable、trace、info counter 和 Goal001 ICMP/UDP；日志是 `plugin-rollback-run.log`、`plugin-rollback-repeat.log` 及 `plugin-rollback/*.log`。失败注入由显式环境变量驱动，正常运行不会触发。

## Stage C：Kubernetes 1.36 SDK 与实际 API

状态：**DONE（单元测试和真实双节点 API/Pod TCP 测试通过）**。本机实际 API server/kubelet 是 Kubernetes v1.36.4；旧 kind 用 v1.33.1。原仓库三个 Kubernetes module 均为 v0.33.1。按[官方 client-go 兼容矩阵](https://github.com/kubernetes/client-go#compatibility-matrix)及三个 v0.36.4 tag 的 `go.mod`，同步固定 `k8s.io/client-go`、`k8s.io/api`、`k8s.io/apimachinery` 为 v0.36.4。v0.36.4 要求 Go 1.26.0；仓库标明 `go 1.26.0` 与 `toolchain go1.26.9`，使用隔离下载工具链。宿主全局 Go 仍是 1.24.13，GoVPP 仍是 v0.13.0，VPP/集群均未升级。

```bash
GOTOOLCHAIN=go1.26.9 go test ./...
GOAL006_CONTROLLER_RESTART=true scripts/goal004/test-physical-pod-service.sh
```

Go 全包测试通过。真实 v1.36.4 双 Ready 节点测试中，Controller watch/list Service/EndpointSlice 并写入 VPP CNAT；美国节点远端 Pod `10.244.0.200`。初始 TCP VIP 40 flows：本地15、远端25；重启 Controller 后新 20 flows：本地9、远端11，重启日志 `services=1 changed=0`，VPP translation 未丢；将远端 EndpointSlice 改为 false 后 10 flows 全走本地，恢复后 40 flows 本地22、远端18。VPP API dump、trace、Stats 与路由/邻居有输出，最后删除本实验 Service/namespace、CNAT、/32 route 并核对宿主默认路由和管理 NIC，cleanup status=0。日志为 `k8s-upgrade-go-test-1269.log`、`k8s136-real-api-pod-service.log`、`k8s136-real-api-restart.log`。

为补充真实 watch 重连，在已授权的隔离 Pod Service 测试里以 `GOAL006_WATCH_DROP=true GOAL006_CONTROLLER_RESTART=true scripts/goal004/test-physical-pod-service.sh` 运行。`scripts/goal006/api-watch-proxy.py` 只监听本机 `127.0.0.1:18086`，TLS 字节流转发到原 API server；仅实验 Controller 使用 root-only 0600 临时 kubeconfig，kubectl 仍直连。代理通过 SIGUSR1 关闭当前 API 连接并拒绝新连接，期间将实验 EndpointSlice 的远端 ready 改为 false：VPP CNAT 仍保留旧 backend，说明 Controller 没收到更新。SIGUSR2 恢复后，CNAT 自动删除远端 backend，10 条新 TCP flow 全到本地；ready 恢复后 20 条新 flow 再次覆盖本地和远端。随后 Controller 重启，20 条 flow 仍覆盖两端；常规 readiness 下线 10 条全本地，恢复 40 条仍覆盖两端。最终代码连续两次测试 exit 0、cleanup status=0、两节点仍 Ready；第二次对应初始 40 条本地19/远端21，watch 恢复后 20 条本地9/远端11，Controller 重启后 20 条本地7/远端13，最终 40 条本地17/远端23。日志 `/root/goal006-evidence/k8s136-real-watch-drop.log`、`k8s136-real-watch-drop-final.log`。这验证了**客户端 watch 连接断开后重新收敛**；没有重启或修改真实 API server。

## Stage D：CI、受影响回归与清理

状态：**DONE**。`.github/workflows/verify.yml` 对 push/main 和 PR 执行 Go format、`go test ./...`、`go vet ./...`、所有 Goal shell 的 `bash -n` 与仓库 Python 文件的 `py_compile`；仅 `contents: read`，Go 固定 1.26.9。首次 [GitHub Actions run 38701599580](https://github.com/oublie6/vpp-cloud-native-service-gateway/actions/runs/38701599580) 在提交 `d9bad08` 上 `completed/success`，各静态/单元检查 step 均为 `success`。root/VPP/SSH/真实集群 E2E 必须本地手动执行。

本机验证：Go format 无输出；`GOTOOLCHAIN=go1.26.9 go test ./...` exit 0、`go vet ./...` exit 0；`bash -n scripts/goal*/*.sh` exit 0；Python `py_compile` exit 0；workflow YAML 可解析。Goal001/002 FIB 与 TAP ICMP 使用 `scripts/goal002/test-fib.sh` 复跑，3/3 ping，route 删除后 0/2，exit 0；Goal002 CNAT TCP/UDP 与删除在 Stage A 的多 worker、单 main 回归通过；Goal003 reconciler 单元测试及 Stage C 真实 API/Pod TCP 通过；Goal004 多 worker 与远端 Pod TCP 见 Stage A/C；Goal005 插件见 Stage B。没有重新运行全部历史 benchmark，也没有硬件吞吐结论。

完成测试后 `ip netns list` 为空、VPP `show interface` 只有 `local0`；宿主默认路由仍经 `eth0` 的 10.0.138.1，管理地址为 10.0.138.51；原 VPP CLI/API 可用。两个真实 Kubernetes 节点的 TCP tunnel、kubelet、containerd 未作为 cleanup 目标。

### 仍需处理

- 独立常驻实例已经加载候选，但输入 feature 必须在 backend 报文入口启用；其他未配置的接口不能直接套用 Goal002 TAP 的成功结论。
- 候选补丁只经过所列功能回归；真实 API server 故障、上游合入/广泛并发压力没有在本 Goal 证明。
- ChatGPT 学习/工程最终验收：**待验收**。

## ChatGPT 正式验收记录（2026-10-16）

结论：**附条件通过（限定独立 VPP + IPv4 TAP 实验）**。核对了固定 VPP 24.10 的实际源码/patch、GoVPP 输入 feature、Goal005 回滚状态机、Kubernetes v0.36.4 工具链、API watch 连接恢复测试和最新 CI。GitHub Actions run [38755515370](https://github.com/oublie6/vpp-cloud-native-service-gateway/actions/runs/38755515370) 在最终提交 `d158473d` 上为 completed/success。服务器 E2E 的数值来自 Codex 归档，非 ChatGPT 当次独立复跑。

限制：原始首次回包失败的竞争解释仍是源码和 trace 支持的推断；候选插件的 reverse session INPUT 路径必须匹配实际 ingress `cnat-input-ip4` 配置，不能把当前仅启用 `tap102` 的测试工具宣称为通用 Controller 功能。C 源码中的共享 IPv4/IPv6 VIP 函数受一行补丁共同影响，但没有 IPv6 回归、Session scanner/aging 长周期与广泛并发验证；不适用生产级修复或真实性能宣称。详见 [Goal006 验收段落](../../docs/goals/006-cnat-multiworker-hardening-and-release.md#11-chatgpt-学习--工程验收结论2026-10-16)。
