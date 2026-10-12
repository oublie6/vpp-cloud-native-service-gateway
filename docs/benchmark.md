# 软件测量边界

Goal 004 的有界测量使用 Python 生成器、Linux namespace/TAP/veth、VPP 24.10 单 `vpp_main`。TCP/UDP 各 100 个新 flow，128 B 应用 payload、目标 200 flows/s；结果及 RX/TX、runtime vectors 见 `results/goal004/README.md`。这只验证功能和有限负载下的计数，不代表吞吐上限或真实 NIC line-rate。

Goal 005 只发少量 ICMP/UDP 用于 feature、trace 和 counter 机制验证，`goal005-observe` runtime 的 Vectors/Call 接近 1 属于低流量事实，不作性能结论。未运行 TRex、pktgen、多 worker handoff 或 DPDK 硬件测试。要声称性能，必须另设实验并记录 CPU/NUMA、worker、packet size、flow count、offered load、RX/TX/drop、生成器和 I/O backend。
