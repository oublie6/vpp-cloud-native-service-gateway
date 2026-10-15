#!/usr/bin/env python3
"""仅转发本实验 controller 的 Kubernetes TLS 字节流，用于可控断开 watch。"""

import argparse
import os
import select
import signal
import socket
import socketserver
import threading
from pathlib import Path
from urllib.parse import urlsplit

import yaml


class ProxyState:
    def __init__(self):
        self.enabled = True
        self.connections = set()
        self.lock = threading.Lock()

    def register(self, pair):
        with self.lock:
            if not self.enabled:
                return False
            self.connections.add(pair)
            return True

    def unregister(self, pair):
        with self.lock:
            self.connections.discard(pair)

    def pause(self, *_):
        with self.lock:
            self.enabled = False
            connections = list(self.connections)
        for pair in connections:
            for conn in pair:
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        print("PAUSED: existing API connections closed", flush=True)

    def resume(self, *_):
        with self.lock:
            self.enabled = True
        print("RESUMED: new API connections accepted", flush=True)


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        state = self.server.state
        try:
            upstream = socket.create_connection(self.server.target, timeout=5)
        except OSError as exc:
            print(f"upstream connect failed: {exc}", flush=True)
            return
        pair = (self.request, upstream)
        with upstream:
            if not state.register(pair):
                return
            try:
                print("API connection established", flush=True)
                while True:
                    readable, _, _ = select.select(pair, [], [], 1)
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        destination = upstream if source is self.request else self.request
                        destination.sendall(data)
            except (OSError, ValueError):
                return
            finally:
                state.unregister(pair)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def configure_kubeconfig(source, destination, listen):
    config = yaml.safe_load(source.read_text())
    current = config["current-context"]
    context = next(item["context"] for item in config["contexts"] if item["name"] == current)
    cluster = next(item["cluster"] for item in config["clusters"] if item["name"] == context["cluster"])
    endpoint = urlsplit(cluster["server"])
    if endpoint.scheme != "https" or not endpoint.hostname:
        raise ValueError("Kubernetes API server 必须是有效 HTTPS 地址")
    target = (endpoint.hostname, endpoint.port or 443)
    cluster.setdefault("tls-server-name", endpoint.hostname)
    cluster["server"] = f"https://{listen}"
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        yaml.safe_dump(config, output)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-kubeconfig", type=Path, required=True)
    parser.add_argument("--agent-kubeconfig", type=Path, required=True)
    parser.add_argument("--listen", default="127.0.0.1:18086")
    args = parser.parse_args()
    host, port_text = args.listen.rsplit(":", 1)
    if host != "127.0.0.1":
        parser.error("仅允许监听 127.0.0.1")
    target = configure_kubeconfig(args.source_kubeconfig, args.agent_kubeconfig, args.listen)
    state = ProxyState()
    with Server((host, int(port_text)), Relay) as server:
        server.state = state
        server.target = target
        signal.signal(signal.SIGUSR1, state.pause)
        signal.signal(signal.SIGUSR2, state.resume)
        print(f"READY: loopback API proxy {args.listen}", flush=True)
        server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    main()
