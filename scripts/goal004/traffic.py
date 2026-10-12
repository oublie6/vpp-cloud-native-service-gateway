#!/usr/bin/env python3
"""Goal 004 local/remote backend 与隔离 VIP 的有界 TCP/UDP 流量验证。"""

import argparse
import selectors
import socket
import time


PORT = 18080
CLIENT = "10.10.1.2"
VIP = "198.19.0.20"
BACKENDS = ("10.10.2.2", "10.10.4.2")


def serve(bind_ip):
    selector = selectors.DefaultSelector()
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((bind_ip, PORT))
    selector.register(udp, selectors.EVENT_READ, "udp")
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.bind((bind_ip, PORT))
    tcp.listen(64)
    selector.register(tcp, selectors.EVENT_READ, "tcp")
    print("backend server ready:", bind_ip, flush=True)
    while True:
        for key, _ in selector.select():
            if key.data == "udp":
                payload, peer = udp.recvfrom(4096)
                udp.sendto(bind_ip.encode() + b":" + payload, peer)
            else:
                conn, _ = tcp.accept()
                with conn:
                    conn.settimeout(3)
                    payload = conn.recv(4096)
                    conn.sendall(bind_ip.encode() + b":" + payload)


def client(proto, flows, base_port, expected, require_both, payload_size, quiet, interval_us):
    seen = {}
    started = time.perf_counter()
    for index in range(flows):
        if interval_us:
            delay = started + index * interval_us / 1_000_000 - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        sock_type = socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM
        payload = (f"{proto}-{index}:".encode() + b"x" * payload_size)[:payload_size]
        with socket.socket(socket.AF_INET, sock_type) as sock:
            sock.settimeout(3)
            sock.bind((CLIENT, base_port + index))
            if proto == "udp":
                sock.sendto(payload, (VIP, PORT))
                reply, peer = sock.recvfrom(4096)
            else:
                sock.connect((VIP, PORT))
                sock.sendall(payload)
                reply = sock.recv(4096)
                peer = sock.getpeername()
        if peer != (VIP, PORT):
            raise RuntimeError(f"反向改写异常: {peer}")
        backend, separator, echoed = reply.partition(b":")
        backend = backend.decode()
        if separator != b":" or backend not in BACKENDS or echoed != payload:
            raise RuntimeError(f"backend 应答异常: {reply!r}")
        if expected and backend != expected:
            raise RuntimeError(f"backend 错误: want={expected} got={backend}")
        seen[backend] = seen.get(backend, 0) + 1
        if not quiet:
            print(proto, "flow", index, "backend", backend, "reply", peer, flush=True)
    if require_both and set(seen) != set(BACKENDS):
        raise RuntimeError(f"未命中本地与远端两个 backend: {seen}")
    elapsed = time.perf_counter() - started
    target = f" target_offered={1_000_000 / interval_us:.0f}flows/s" if interval_us else " unpaced"
    print(f"{proto} flows={flows} payload={payload_size} elapsed={elapsed:.6f}s{target} distribution={seen}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("server", "client"))
    parser.add_argument("--bind", choices=BACKENDS)
    parser.add_argument("--proto", choices=("udp", "tcp"), default="udp")
    parser.add_argument("--flows", type=int, default=20)
    parser.add_argument("--base-port", type=int, default=30000)
    parser.add_argument("--expect-backend", choices=BACKENDS)
    parser.add_argument("--require-both", action="store_true")
    parser.add_argument("--payload-size", type=int, default=64)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--interval-us", type=int, default=0)
    args = parser.parse_args()
    if args.action == "server":
        if args.bind is None:
            parser.error("server 必须指定 --bind")
        serve(args.bind)
    else:
        if args.flows < 1 or args.base_port < 1024 or args.base_port + args.flows > 65535:
            parser.error("flow 数或源端口范围无效")
        if args.payload_size < 1 or args.payload_size > 4000:
            parser.error("payload size 必须在 1..4000")
        if args.interval_us < 0:
            parser.error("interval-us 不能为负")
        client(args.proto, args.flows, args.base_port, args.expect_backend, args.require_both, args.payload_size, args.quiet, args.interval_us)


if __name__ == "__main__":
    main()
