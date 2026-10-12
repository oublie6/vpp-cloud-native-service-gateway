#!/usr/bin/env bash
# Goal 004 两个逻辑节点的软件拓扑命名与地址。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../goal001/topology-common.sh"

REMOTE_NS=g004-remote
ROUTER_IF=g004uplink
REMOTE_IF=g004eth
ROUTER_ADDR=10.10.3.1/30
REMOTE_ADDR=10.10.3.2/30
REMOTE_NEXT_HOP=10.10.3.1
REMOTE_BACKEND=10.10.4.2
REMOTE_BACKEND_ADDR=10.10.4.2/32
REMOTE_MARKER=$RUNTIME/goal004-owned
REMOTE_BEFORE=$RUNTIME/goal004-before.txt

require_goal001_topology() {
  [[ -f "$MARKER" ]] || die 'Goal 001 topology marker 不存在'
  ip netns exec "$SERVER_NS" ip link show "$SERVER_HOST_IF" >/dev/null 2>&1 || die 'Goal 001 server TAP 不存在'
  vpp_cli 'show interface' | grep -Fq "$SERVER_VPP_IF" || die 'Goal 001 VPP server TAP 不存在'
}
