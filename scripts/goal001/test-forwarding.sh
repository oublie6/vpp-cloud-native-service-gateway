#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/topology-common.sh"
require_root
require_vpp
[[ -f "$MARKER" ]] || die '请先运行 setup-topology.sh 与 configure-forwarding.sh'

printf '%s\n' '=== ICMP: client -> server ==='
ip netns exec "$CLIENT_NS" ping -n -c 3 -W 2 "${SERVER_ADDR%/*}" || die 'ICMP 验证失败'

# UDP server 在 server namespace 回发 payload，验证请求和响应都经过 VPP。
ready=$RUNTIME/udp-ready
rm -f -- "$ready"
ip netns exec "$SERVER_NS" python3 -u -c '
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(10)
sock.bind(("10.10.2.2", 19001))
open("/run/vpp-goal001/udp-ready", "w").close()
payload, peer = sock.recvfrom(256)
if payload != b"goal001-udp":
    raise SystemExit("unexpected UDP payload")
sock.sendto(b"goal001-ack", peer)
print("UDP server received goal001-udp and sent goal001-ack")
' &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -f -- "$ready"' EXIT
for attempt in {1..50}; do
  [[ -f "$ready" ]] && break
  sleep 0.1
done
[[ -f "$ready" ]] || die 'UDP server 未就绪'
printf '%s\n' '=== UDP: client -> server -> client ==='
ip netns exec "$CLIENT_NS" python3 -c '
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(5)
sock.bind(("10.10.1.2", 0))
sock.sendto(b"goal001-udp", ("10.10.2.2", 19001))
data, peer = sock.recvfrom(256)
if data != b"goal001-ack" or peer[0] != "10.10.2.2":
    raise SystemExit("unexpected UDP reply")
print("UDP client received goal001-ack from", peer)
' || die 'UDP 验证失败'
wait "$server_pid" || die 'UDP server 失败'
rm -f -- "$ready"
trap - EXIT
