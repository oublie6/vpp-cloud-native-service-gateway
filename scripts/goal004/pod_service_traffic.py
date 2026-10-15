#!/usr/bin/env python3
"""经隔离 VPP VIP 验证本地 backend 与真实远端 Pod 的 TCP 回包。"""

import argparse
import socket


REQUEST = b"GET / HTTP/1.0\r\nHost: goal004\r\n\r\n"


def run(vip: str, pod_ip: str, flows: int, base_port: int, expected: str) -> None:
    seen = {"local": 0, "remote": 0}
    for index in range(flows):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.bind(("10.10.1.2", base_port + index))
            sock.connect((vip, 18080))
            sock.sendall(REQUEST)
            reply = bytearray()
            while part := sock.recv(4096):
                reply.extend(part)
            if sock.getpeername() != (vip, 18080):
                raise RuntimeError(f"flow {index}: TCP peer 不是隔离 VIP")

        if reply == b"10.10.2.2:" + REQUEST:
            backend = "local"
        elif reply.startswith(b"HTTP/1.1 200 OK\r\n") and reply.split(b"\r\n\r\n", 1)[-1] == pod_ip.encode() + b"\n":
            backend = "remote"
        else:
            raise RuntimeError(f"flow {index}: backend 响应不匹配：{bytes(reply[:120])!r}")
        seen[backend] += 1

    if expected == "both" and not all(seen.values()):
        raise RuntimeError(f"未同时命中本地与远端 backend：{seen}")
    if expected in ("local", "remote") and seen[expected] != flows:
        raise RuntimeError(f"预期全部命中 {expected}：{seen}")
    print(f"TCP VIP {vip}: {flows} flows, local={seen['local']}, remote Pod={seen['remote']}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vip", default="198.19.0.20")
    parser.add_argument("--pod-ip", required=True)
    parser.add_argument("--flows", type=int, required=True)
    parser.add_argument("--base-port", type=int, required=True)
    parser.add_argument("--expect", choices=("both", "local", "remote"), required=True)
    args = parser.parse_args()
    if args.flows < 1 or args.base_port < 1024 or args.base_port + args.flows > 65535:
        parser.error("无效的 flow 数或源端口范围")
    run(args.vip, args.pod_ip, args.flows, args.base_port, args.expect)


if __name__ == "__main__":
    main()
