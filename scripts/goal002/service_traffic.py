#!/usr/bin/env python3
"""Goal 002 namespace 内的 TCP/UDP backend 与 VIP 客户端验证器。"""

import argparse
import selectors
import socket
import time

BACKENDS = ("10.10.2.2", "10.10.2.3")
CLIENT = "10.10.1.2"
VIP = "198.18.0.10"
PORT = 18080


def serve(reply_delay):
    selector = selectors.DefaultSelector()
    for ip in BACKENDS:
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind((ip, PORT))
        selector.register(udp, selectors.EVENT_READ, ("udp", ip))
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tcp.bind((ip, PORT))
        tcp.listen(64)
        selector.register(tcp, selectors.EVENT_READ, ("tcp", ip))
    print("backend server ready: " + ", ".join(BACKENDS), flush=True)
    while True:
        for key, _ in selector.select():
            protocol, ip = key.data
            if protocol == "udp":
                payload, peer = key.fileobj.recvfrom(4096)
                if reply_delay:
                    time.sleep(reply_delay)
                key.fileobj.sendto(ip.encode() + b":" + payload, peer)
                print("udp", ip, "from", peer, flush=True)
            else:
                conn, peer = key.fileobj.accept()
                with conn:
                    conn.settimeout(3)
                    payload = conn.recv(4096)
                    if reply_delay:
                        time.sleep(reply_delay)
                    conn.sendall(ip.encode() + b":" + payload)
                print("tcp", ip, "from", peer, flush=True)


def client(protocol, flows, base_port, repeats, expected_backend, require_both, vip):
    seen = {}
    for i in range(flows):
        socktype = socket.SOCK_DGRAM if protocol == "udp" else socket.SOCK_STREAM
        with socket.socket(socket.AF_INET, socktype) as sock:
            sock.settimeout(3)
            sock.bind((CLIENT, base_port + i))
            first_backend = None
            for repeat in range(repeats):
                payload = (protocol + "-flow-" + str(i) + "-repeat-" + str(repeat)).encode()
                if protocol == "udp":
                    sock.sendto(payload, (vip, PORT))
                    data, peer = sock.recvfrom(4096)
                else:
                    if repeat == 0:
                        sock.connect((vip, PORT))
                    sock.sendall(payload)
                    data = sock.recv(4096)
                    peer = sock.getpeername()
                if peer != (vip, PORT):
                    raise RuntimeError("逆向改写异常: peer=" + repr(peer))
                backend, sep, echoed = data.partition(b":")
                backend = backend.decode()
                if not sep or echoed != payload or backend not in BACKENDS:
                    raise RuntimeError("backend 应答异常: " + repr(data))
                if first_backend is not None and backend != first_backend:
                    raise RuntimeError("同一 flow 的 backend 改变: " + first_backend + " -> " + backend)
                first_backend = backend
            backend = first_backend
            if expected_backend and backend != expected_backend:
                raise RuntimeError("backend 错误: want=" + expected_backend + " got=" + backend)
            seen[backend] = seen.get(backend, 0) + 1
            print(protocol, "flow", i, "backend", backend, "repeats", repeats, "reply", peer, flush=True)
    if require_both and set(seen) != set(BACKENDS):
        raise RuntimeError("多 backend 分布不足: " + repr(seen))
    print(protocol, "distribution", seen, flush=True)
    return seen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("server", "client"))
    parser.add_argument("--proto", choices=("udp", "tcp"), default="udp")
    parser.add_argument("--flows", type=int, default=20)
    parser.add_argument("--base-port", type=int, default=20000)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--expect-backend", choices=BACKENDS)
    parser.add_argument("--require-both", action="store_true")
    parser.add_argument("--vip", default=VIP)
    parser.add_argument("--reply-delay", type=float, default=0.0)
    args = parser.parse_args()
    if args.action == "server":
        if args.reply_delay < 0:
            parser.error("reply delay must be nonnegative")
        serve(args.reply_delay)
    else:
        if args.flows < 1 or args.base_port + args.flows > 65535 or args.repeats < 1:
            parser.error("invalid flow count or source port range")
        if args.proto == "tcp" and args.repeats != 1:
            parser.error("TCP backend 测试只支持每连接一个请求")
        client(args.proto, args.flows, args.base_port, args.repeats, args.expect_backend, args.require_both, args.vip)


if __name__ == "__main__":
    main()
