# 2026-10-09 Goal 001 运行机制、DPO 并发与跨对话接续

> 定位：Goal 001 **工程已完成、已验收**；本文是 2026-10-06～10-09 的源码回讲与学习进度快照，不是新的实验结果，也不把 Goal 002 标为启动。真实证据以 [Goal001 results](../results/goal001/README.md) 为准；旧笔记中的术语/版本若与本文冲突，以 **VPP v24.10 官方源码和已验收运行证据**为准。

## 1. 当前权威状态

- 工程：Goal 001 Stage 1～4 ✅ 已实现、真实 VPP 环境测试、ChatGPT 已验收；下一工程阶段 Goal 002 = GoVPP Control Plane / FIB / Stats / CNAT Service，**尚未启动**。
- 讲解：Goal001 的 runtime、graph、frame、FIB/DPO/adjacency、worker/RTC、trace、barrier/atomic/refcount、rewrite 更新基本讲透；教学复盘粗略还有约 **20%～25%**，非实验性百分比、不可等同项目整体完成度。
- 环境：Ubuntu 20.04，kernel 5.4.0-216-generic，VPP **24.10-release**，GoVPP v0.13.0，Go 1.24.13；软件 TAP/VIRTIO，不代表真实 NIC/DMA 线速。
- 本轮没有新增运行测试；本文“源码确认”与“Goal001 实机证据”分别标记。

## 2. Goal001 已证实的工程事实

1. `Go → GoVPP → Binary API socket (/run/vpp-goal001/api.sock) → VPP`；CLI socket 独立。
2. Linux namespace/TAP/VPP：`g001-client (10.10.1.2/24) ↔ tap101 (VPP 10.10.1.1/24) ↔ VPP ↔ tap102 (10.10.2.1/24) ↔ g001-server (10.10.2.2/24)`；TAP 的 client ID/name 用于稳定识别，`sw_if_index` 运行时可能变化。
3. Stage3：connected/attached `10.10.2.0/24` 的 glean；邻居完成后存在 `10.10.2.2/32` resolved forwarding、LB DPO 和完整 rewrite adjacency。首次 ICMP 3 发 2 收，后续 ICMP 3/3；UDP request/reply payload 验证通过。**证据显示前后状态，不冒充每一个中间 incomplete adjacency 的实测**。
4. Stage4 一条成功 IPv4 packet trace：`virtio-input → ethernet-input → ip4-input → ip4-lookup → ip4-rewrite → tap102-output → tap102-tx`，反向同理。该实际路径**没有单独的 ip4-load-balance node**；LB bucket selection 已融合在此版本普通 `ip4-lookup`，而 `ip4-load-balance` 在其他续接场景仍可存在。
5. `show runtime`：`virtio-input` 大量空轮询 calls、少量 vectors，`Vectors/Call≈0`；低流量内部 node 大多 `≈1`；不能由累计计数推导单包完整流或真实性能。Goal001 `show threads` 只有 vpp_main，没有额外 worker；以下多 worker 理论需另行实验。
6. 重启重跑后接口 index/MAC 改变仍通过；清理回收 namespace/TAP，管理 NIC 和默认路由保持。脚本后续可加强：VPP 崩溃后 cleanup 不应强耦合实例可用性；`configure-forwarding.sh` 的地址检查可按接口作用域收紧。

## 3. 关键心智模型与误解纠正

### 3.1 三层图

- FIB/control dependency graph：路由来源、路径依赖、back-walk/重新收敛；不等于 fast-path VLIB graph。
- DPO graph：已预计算的 forwarding continuation，LB bucket 保存下一级 DPO handle；`dpoi_index` 表示具体 forwarding object index，`dpoi_next_node` 是相对起点 VLIB node 的 next-edge slot（**不是全局 node ID**）。
- VLIB graph：函数执行路径。Node 为 packet processing code；frame 通常传 `vlib_buffer_t` index 而不是复制整个 payload；同 worker RTC 串起 graph，edge 不代表跨核 handoff。

**重要正式修正：DPO stack parent/child 曾被倒置**。按 `src/vnet/dpo/dpo.h` 对 `dpo_stack(child_type, child_proto, slot, parent_dpo)` 的定义：**LB 是 Child，adjacency 是 Parent；LB 的 bucket slot 持有 Parent DPO 的 continuation**。此处的 parent/child 是 DPO stacking 依赖语义，勿按“转发箭头起点=parent”直觉倒置。一个 LB 可以有多个 bucket/slot，各自引用不同 parent DPO；一个 slot 同时只保存一个 parent continuation。

### 3.2 Worker main loop 与 barrier

按 `src/vlib/main.c`：worker 每轮开头检查 `vlib_worker_thread_barrier_check()`；之后处理 frame queue、input、pending frames（循环 dispatch，直到该轮 pending vector drain）、再进入下一轮。barrier **不是每个 node return 就停车**，而是在下一轮 main-loop boundary 的 quiescent point park。缓存 frame/buffer 对象仍可能存在，不能把 quiescence 解释成所有 buffer 被释放。

`src/vlib/threads.h`/`threads.c`：main 置 `wait_at_barrier=1`，等待 `workers_at_barrier==worker_count`；安全修改并 release。RX 设备/queue 并不会因 worker 停止而停止进包，所以要控制 barrier 的时长、频率。和 DPDK QSBR 对照：barrier = 同步让所有 worker park 再修改/回收；QSBR/RCU = publish 新版，reader 不必全停，等待 grace period 再回收。

### 3.3 Vector activity / adaptive input 调度

按 `src/vlib/node.h`、`node_funcs.h`、`main.h`、`main.c`：
- `VLIB_LOG2_MAIN_LOOPS_PER_STATS_UPDATE=7`，窗口 **128 次 main loop**，不是固定 128 μs，也不是滑动 0～127、1～128 的窗口；
- 每个 node `main_loop_vector_stats[2]` 两个桶轮换。当前 epoch `k=floor(main_loop_count/128)` 写 `bucket[k%2]`，更新函数返回上一个**完整** epoch 的累计 `n_vectors`；平均值可除以 128；
- dispatcher 对 adaptive input 在 dispatch 时评估上一窗口的 activity，不是只在每个 128-loop 边界调用一次；
- `polling_threshold_vector_length=10`，`interrupt_threshold_vector_length=5` 为 24.10 默认**窗口累计计数比较**，不是单次 RX burst 的 10/5；polling→interrupt 还有额外 dispatch/driver re-enable 阶段；backend 支持 adaptive 与否需实际检查，不可由 API 存在推断 TAP 一定支持。
- `show runtime` 的 `Vectors/Call` 是该 node 累计 vectors/calls，**不是**上一 128-loop 的 adaptive activity；busy polling 的 idle calls 很多完全正常。

### 3.4 Atomic DPO slot、引用计数与释放

真实 24.10 源码：`src/vnet/dpo/dpo.h` 的 `dpo_id_t` 为含 type/proto/next_node/index 的 ≤64-bit handle；`src/vnet/dpo/dpo.c::dpo_copy()` 用 `dst->as_u64=src->as_u64` 一次整体 publish，随后 `dpo_lock(dst)` / `dpo_unlock(old)`。`dpo_stack_i()` 用私有 tmp 填好 parent handle 和 edge 后整体替换。LB bucket：`src/vnet/dpo/load_balance.c::load_balance_set_bucket_i()` → `dpo_stack()` → `dpo_copy()`。调用可源于 FIB/path-list 重算；**worker fast path 不逐包 swap/refcount**。

必须把三件事分开：
1. **atomic publish**：不让数据面看到 DPO handle 的“旧 type + 新 index”等半更新组合；
2. **长期控制面 refcount**：DPO handle 指向的底层对象由各自 type 的 `dv_lock/dv_unlock` 维护，**不是每个 64-bit handle 自带独立 refcount**；Adj DPO → `adj_lock/unlock` → `fib_node.fn_locks`；
3. **dataplane grace period**：Adj 最后一个 lock 归零，`adj_last_lock_gone()` 在 `pool_put(adj_pool, adj)` 之前执行 worker barrier，等待已拿到旧 index 的 packet 退出 worker 本轮 graph execution。

例如两个 LB buckets 都持有 Adj#5，refcount=2；只替换其中一个为 Adj#8 后仍有另一个 bucket，**barrier 不能代替 refcount**，否则将来那个 bucket 仍可能引用已释放 Adj#5；最后长期引用离开后仍必须 barrier 才能安全释放**已在途** reader。这里特别说明：Adj 生命周期路径已在 VPP24.10 核对，**不能直接宣称所有 DPO type 都一样 barrier free**。

### 3.5 修改 Adj 自身与 DPO slot 不同

`src/vnet/adj/adj_nbr.c::adj_nbr_update_rewrite_internal()`：修改 MAC/L2 rewrite string 是多字节/多字段操作，不能当成 64-bit DPO ID swap；因此需要 worker barrier。当 adjacency 在 incomplete↔complete 间**改变类型**，其 child DPO graph next-node 也需一致：先同步 back-walk 使 children 暂时 stack 到 DROP，barrier 内修改 `lookup_next_index`、node/rewrite/edge，release 后 back-walk restack children。函数更新前临时 `adj_lock`，防止 child 暂离时 refcount 降为 0 提前销毁；更新完成再 unlock。这也是“refcount 管长期 ownership、barrier 管当前 in-flight reader/多字段修改”的实例。

### 3.6 Barrier 并非所有 FIB 变更通用路径

`src/vnet/dpo/dpo.c::dpo_stack_from_node()` 只在原 VLIB next edge 不存在而需要 `vlib_node_add_next()` 时使用 barrier，已有 slot 的 atomic stack 不先全局暂停；`src/vnet/adj/adj.c::adj_alloc()` 如果 adjacency pool 或 counter pool 即将扩容也会 barrier，保护已在运行的池访问。不同 subsystem 要按 matching-tag 代码分别确认，不要推断“所有 route 更新都 worker barrier”或“只要 DPO 就全部 atomic”。

## 4. 进度、未完成知识与新对话恢复

**Goal001 工程：✅ 完成**；**Goal001 理论回讲：约 75%～80%（仅教学主观估计）**。本轮进展：adaptive activity 双桶、V/C、RTC loop boundary、barrier、DPO atomic、Adj refcount/lifetime、rewrite/neighbor type-change 全部结合正式源码解释，用户能复述并自行纠正 node/worker boundary。

**下一次先补这四块，再开始 Goal002：**
1. **Glean→ARP→Neighbor resolution→/32 resolved adjacency**：按 Goal001 Stage3 before/after 证据和 24.10 source 解释首包 3 发 2 收；不要虚构 incomplete 中间态已测到。
2. 请求/应答完整 L3/L2/TTL/邻居方向；UDP E2E payload 和首次 ARP 对照。
3. Stage4 `show trace` vs `show runtime` / errors / interfaces 能证明与不能证明什么；Goal001 cleanup/异常情形及可改进项。
4. 少量复盘问答，锁定 Goal001 教学收尾；再设计 **Goal002 GoVPP FIB/Stats/CNAT**，先核对与 VPP 24.10 对应 CNAT API/schema，禁止先臆造 API 或直接跳到 Kubernetes Goal003。

新会话读取顺序：本文件 → [Goal001 验收](goals/001-vpp-govpp-environment-baseline.md) → [真实证据](../results/goal001/README.md) → README/AGENTS → 高性能学习仓库对应 2026-10-09 笔记。回答 VPP 问题必须再次核对 matching-tag 官方源码/文档；不要把本笔记作为新的独立权威。

## 5. 官方一手参考（精确 tag）

- https://github.com/FDio/vpp/blob/v24.10/src/vlib/main.c
- https://github.com/FDio/vpp/blob/v24.10/src/vlib/main.h
- https://github.com/FDio/vpp/blob/v24.10/src/vlib/node.h
- https://github.com/FDio/vpp/blob/v24.10/src/vlib/node_funcs.h
- https://github.com/FDio/vpp/blob/v24.10/src/vlib/threads.h
- https://github.com/FDio/vpp/blob/v24.10/src/vlib/threads.c
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/dpo/dpo.h
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/dpo/dpo.c
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/dpo/load_balance.c
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/adj/adj.c
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/adj/adj_nbr.c
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/fib/fib_node.c
- https://github.com/FDio/vpp/blob/v24.10/src/vnet/ip/ip4_forward.c

## 下一步

新对话从 Goal001 **glean/ARP 首包状态迁移与证据**继续；不重讲已验证的 DPO/barrier 基础，也不提前宣称 Goal002 完成。
