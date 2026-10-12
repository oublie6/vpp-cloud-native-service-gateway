# Goal 005 真实运行证据

状态：Codex 已实现并在 VPP 24.10 实测；ChatGPT 学习 / 工程验收待验收。

## 版本、构建与排障

Ubuntu 20.04 focal、kernel 5.4.0-216-generic、VPP 24.10-release、Go 1.24.13、GoVPP v0.13.0。为编译插件安装与 VPP 同版本的 `vpp-dev=24.10-release`、`libvppinfra-dev=24.10-release`，以及 Ubuntu CMake/Ninja/GCC、`python3-ply`；`apt-get -s` 预检为 0 upgraded，现有 VPP 未升级。安装前记录了 route/interface、VPP 版本、package 和 HugePages；未更改管理网络。

`vppapigen` 最初因缺 `ply` 失败，安装 `python3-ply` 后 C/JSON 生成成功。CMake 3.16 报告不支持 `DEPFILE` 的警告，但 Ninja 构建成功。计数器初版只填 `.name`，`show errors` 显示 `(nil)`；补 `.desc` 后复验显示 `observed IPv4 packets`，severity=`info`。首次脚本用 `trace add virtio-input 8` 时，背景 IPv6 multicast 占据 trace 配额，虽 ICMP/UDP 成功但未捕到完整成功路径；改为固定 24 个并断言 node/rewrite/output，复跑通过。失败的脚本仍自动 cleanup。这些均为真实排障记录。

```bash
cmake -S plugins/goal005-observe -B /tmp/goal005-build -G Ninja
cmake --build /tmp/goal005-build
# 构建生成 /tmp/goal005-build/observe.api.json；GoVPP v0.13.0 模块目录运行：
go run ./cmd/binapi-generator --input /tmp/goal005-api \
  --output-dir /root/vpp-cloud-native-service-gateway/internal/goal005binapi \
  --no-version-info --no-source-path-info observe
```

`/tmp/goal005-api` 中放构建生成的 `observe.api.json` 和系统 VPP 24.10 `/usr/share/vpp/api/core/{interface_types,memclnt}.api.json`。由此产生的 `internal/goal005binapi` 已提交；没有随机升级 GoVPP 依赖。

## 真实 E2E

在测试前 VPP 仅 `local0`，无 Goal 001 namespace/TAP，默认 route 为 `default via 10.0.138.1 dev eth0 proto static`。脚本临时把构建的 `.so` 装到 VPP24.10 plugin 目录，重启独立 VPP，`show plugins` 确认 `goal005_observe_plugin.so 0.1.0`。Goal 001 拓扑为：

```text
g001-client 10.10.1.2/24 -> g001tapc / VPP tap101 10.10.1.1/24
    -> VPP tap102 10.10.2.1/24 -> g001taps / g001-server 10.10.2.2/24
```

`go run ./cmd/goal005-observe enable tap101` 返回 `sw_if_index=1 retval=0`；`show interface features tap101` 在 `ip4-unicast` 下列出 `goal005-observe`。不存在的 interface 返回非零。`scripts/goal005/test-plugin.sh` 最终复跑退出码 0：ICMP 3 发 2 收，首包走 `ip4-glean`/ARP 后丢弃、后两包成功；UDP `goal001-udp` 请求、`goal001-ack` 回复成功。关闭 feature 后 ICMP 2/2 成功，`ip4-unicast` 为 `none configured`，观察计数保持 4 没有增长。

成功 packet 的真实 trace 关键路径：

```text
virtio-input -> ethernet-input -> ip4-input
 -> goal005-observe rx 1 10.10.1.2 -> 10.10.2.2 next 0
 -> ip4-lookup (fib 0 dpo-idx 5)
 -> ip4-rewrite (via 10.10.2.2 tap102, L2 rewrite)
 -> tap102-output
```

`next 0` 是该 feature node 的运行时 next index，真实下个 node 由 trace 确认为 `ip4-lookup`。本 node 从 frame 逐个取 buffer，只读取 IPv4 src/dst 和 RX sw_if_index，`vnet_feature_next` 选择后继，`vlib_buffer_enqueue_to_next` 交还 VPP graph；未修改/释放 packet。`show runtime` 为 `goal005-observe active Calls=4 Vectors=4 Vectors/Call=1.00`。`show threads` 只有 `vpp_main`，无额外 worker。`show errors` 的插件 info counter 为 `4 observed IPv4 packets`；首包 `ip4-glean` ARP 和 drop 与邻居解析相符。最终复跑另有 `null-node blackholed packets=10`；逐条查看 trace，来自 TAP namespace 自动发出的 IPv6 multicast、IPv6 未配置，非插件处理的 IPv4。低流量 vector size 不构成性能证据。

## Cleanup 与门槛

脚本删除 Goal 001 TAP/namespace、停独立 VPP、仅移除本次安装的插件 `.so`，再启动独立 VPP。结束时 VPP 只有 `local0`；无 `g001-client`/`g001-server`，无 Goal005 plugin 文件或已加载 plugin；默认 route、`eth0` IPv4 和原 namespace 列表不变。原有 Docker/container/bridge 没有被本实验清理或修改。

最终 `scripts/goal005/test-plugin.sh` 从仅 `local0` 的干净拓扑复跑退出码 0，cleanup 的 route/`eth0` IPv4/namespace/plugin 检查均为 `passed`。`go test ./...`、`go vet ./...`、`bash -n scripts/goal001/*.sh scripts/goal002/*.sh scripts/goal003/*.sh scripts/goal004/*.sh scripts/goal005/*.sh`、`python3 -m py_compile scripts/goal002/service_traffic.py scripts/goal004/traffic.py`、`git diff --check` 均通过。运行完整输出留在本机 `/tmp/goal005-final-run.log`、完整 trace 留在 `/tmp/goal005-last-trace.txt`；仓库只保留关键证据，不提交大日志。
