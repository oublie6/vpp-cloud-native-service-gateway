# v0.1.0 实验/学习版封版记录

> 状态：**已封版（2026-10-16）**。定位为可复现的 VPP/GoVPP/Kubernetes 云原生 Service Gateway **软件数据面实验与源码学习项目**；不是生产级产品、上游 CNAT 正式修复或硬件性能宣称。
>
> 版本快照：GitHub **归档分支** `release/v0.1.0`（不是 Git tag、不是 GitHub Release，也不是仓库权限级的 branch protection）。后续维护不得强制推送/重写该分支；新开发必须由用户另行授权，并保留本快照可追溯性。

## 交付范围（Goal001～006）

| Goal | 交付 | 封版审查边界 |
| --- | --- | --- |
| 001 | 独立 VPP runtime、GoVPP、TAP/namespace、IPv4 L3 转发、FIB/DPO/邻接与 trace | 完成、正式功能验收通过 |
| 002 | GoVPP FIB/Stats、CNAT TCP/UDP VIP、双后端、Session、增删 | 代码/实测证据审查通过 |
| 003 | Service/EndpointSlice Informer、desired state、幂等 Reconciler、重启恢复 | 代码/实测证据审查通过 |
| 004 | 双逻辑节点、真实双 Ready Kubernetes 节点、远端 Pod TCP 路径及恢复 | 软件路径与真实远端 Pod 实验通过；多 worker 原始缺陷由 Goal006 定向缓解；仍为受限功能验证 |
| 005 | VPP ip4-unicast 观测插件、VLIB frame/buffer、custom Binary API/GoVPP、trace/counter | 功能审查通过；Goal006 增补异常回滚 |
| 006 | CNAT 双 worker UDP 首包候选修复、插件回滚故障注入、Kubernetes SDK 1.36、真实 API watch 重连、CI | **ChatGPT 附条件通过**：Stage B/C/D 通过，Stage A 只在独立 VPP IPv4 TAP、显式输入 feature 场景得到证明 |

仓库证据分别见 `results/goal001`～`results/goal006`；最终验收见 `docs/goals/006-cnat-multiworker-hardening-and-release.md` 第 11 节。

## 版本与验证基线

- VPP：24.10-release；GoVPP：v0.13.0；`k8s.io/client-go`、`api`、`apimachinery`：v0.36.4。
- Go：`go 1.26.0` / `toolchain go1.26.9`；真实 Kubernetes API Server：v1.36.4，历史 kind v1.33.1。
- I/O：Linux TAP/namespace；跨主机补充实验经 SSH/TCP TUN，非原生 UDP 或硬件 NIC。
- 最终验收源码与运行记录截至 `d158473d775c74383e1fa8db9c63cf4ff82f321e`；上一次 ChatGPT 验收记录提交 `ecfa8cec4068d98da38ac7a76b519e2e786f8b90`。
- `ecfa8cec` 的 [GitHub Actions](https://github.com/oublie6/vpp-cloud-native-service-gateway/actions/runs/38785522421) 已完成且成功；包括格式、`go test ./...`、`go vet ./...`、`bash -n`、Python 编译语法。新封版文档提交只修改文档；对应 CI 状态以 GitHub 实际结果为准。
- Root/VPP 及真实双节点 E2E 的数值来自已归档的 Codex 运行记录，并非 ChatGPT 在封版当日独立登录服务器复跑。

## 严格保留的局限

1. Goal006 CNAT 最小补丁把 VIP reverse session 的 `CNAT_LOCATION_FIB` 改成 `CNAT_LOCATION_INPUT`，需要在实际接收后端应答的 **IPv4 ingress 接口**启用 `cnat-input-ip4`。现有 `cmd/goal006-feature` 为 `tap102` 专用，`vpp-service-agent` 未通用化管理此 feature；加载插件不代表任何接口自动修复。
2. 修复竞争的解释由 VPP 24.10 对应源码与 trace 支持，尚非唯一根因的形式证明。共享的 IPv4/IPv6 VIP 处理函数受补丁影响，但 IPv6、其他 ingress、Session aging/scanner 与高并发压力没有完成系统回归。候选补丁不能宣称生产可用或已经被 FD.io 上游合入。
3. Linux TAP 及 SSH/TCP TUN 软件数据路径证据，不等于原生公网 WireGuard UDP 恢复、DPDK 真实网卡性能、line-rate 或生产 HA。
4. 现有 Goal001 独立 VPP 可能加载专用目录下的候选 `cnat_plugin.so`，发行版 CNAT 插件文件未被覆盖。回退方式与前置安全检查见 `scripts/goal006/deploy-cnat.sh` 与 `results/goal006/README.md`。**封版不要求停机、回退当前在线实验实例或改变任何宿主网络设置**。

## 冻结规则与后续工作

- Goal001～006 功能主线 **截至此版本封板**；不自动建立 Goal007，不进行额外业务功能开发、版本大升级或重构。
- 归档分支 `release/v0.1.0` 作为固定快照，后续不得移动或覆盖（这是协作约定，非 GitHub 强制保护）。
- 若发现安全/功能 bug，可在用户新的明确授权后新建独立修复分支并评审，保留本封版版本；不得直接破坏既有证据或将未测试的改动记为此版本能力。
- 后续主要工作转换为**源码学习、技术知识归档、架构讲解、面试/简历材料与经验总结**，原则上不修改封版代码。
