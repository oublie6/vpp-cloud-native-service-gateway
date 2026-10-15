# Goal 006 运行证据（2026-10-15）

环境：Ubuntu 20.04 / kernel 5.15.0-139、VPP 24.10-release、GoVPP v0.13.0。实验使用 Goal001 的 Linux TAP 与 namespace；`tap101` 接 `ns-client` 10.10.1.2，`tap102` 接 `ns-server` 10.10.2.2；VIP 为 198.18.0.10:18080，两个 UDP backend 是 10.10.2.2/.3:18080。默认路由、管理接口以及两个真实 Kubernetes 节点不属于实验资源。

大型日志、pcap、core 和宿主快照只保存在本机 root 可读目录 `/root/goal006-evidence/`，不提交仓库。下面保留可复跑命令和关键观测；本机路径不构成跨机器共享证据。

## Stage A：CNAT 多 worker 首个 UDP 回包

状态：**BLOCKED（隔离补丁和回归已通过，常驻实例部署待单独授权）**。Goal006 明确要求修改系统安装的插件前单独授权，故仓库保留 patch 和独立构建入口，当前常驻 VPP 仍加载发行版 CNAT。

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

补丁改变 reverse session 的 lookup 位置，并在接收后端报文的接口启用输入 feature；生命周期仍由 VPP 原有 CNAT session 机制管理。独立加载和关闭即可回退到发行版插件。由于未改常驻插件，此处不能声称常驻双 worker 已修好；补丁也只做了有限功能回归，不是并发正确性的形式证明。

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

- 常驻发行版 CNAT 插件未替换，常驻实例尚不具备隔离候选补丁的零延迟双 worker 保证；安装/切换常驻插件按 Goal006 和 AGENTS.md 第 19 节需要用户单独授权。
- 独立候选补丁只经过所列功能回归；真实 API server watch 网络中断、上游合入/广泛并发压力没有在本 Goal 证明。
- ChatGPT 学习/工程最终验收：**待验收**。
