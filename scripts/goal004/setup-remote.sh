#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/remote-common.sh"
require_root
require_vpp
require_goal001_topology

if [[ -e "$REMOTE_MARKER" ]]; then
  ip netns exec "$SERVER_NS" ip link show "$ROUTER_IF" >/dev/null 2>&1 || die 'Goal 004 marker 存在但 router veth 不在'
  ip netns exec "$REMOTE_NS" ip link show "$REMOTE_IF" >/dev/null 2>&1 || die 'Goal 004 marker 存在但 remote veth 不在'
  ip -n "$REMOTE_NS" route show default | grep -Fq "$REMOTE_NEXT_HOP" || die 'Goal 004 marker 存在但 remote 默认路由不在'
  go run ./cmd/goal004-route inspect | grep -Fq 'present' || die 'Goal 004 marker 存在但 VPP 远端路由不在'
  printf 'Goal 004 远端拓扑已存在\n'
  exit 0
fi
! ip netns list | grep -Eq "^${REMOTE_NS}( |$)" || die "$REMOTE_NS 已存在但非本脚本所有"
! ip link show "$ROUTER_IF" >/dev/null 2>&1 || die "$ROUTER_IF 已存在但非本脚本所有"
! ip link show "$REMOTE_IF" >/dev/null 2>&1 || die "$REMOTE_IF 已存在但非本脚本所有"
! ip netns exec "$SERVER_NS" ip link show "$ROUTER_IF" >/dev/null 2>&1 || die "$ROUTER_IF 已存在但非本脚本所有"

forward_before=$(ip netns exec "$SERVER_NS" sysctl -n net.ipv4.ip_forward)
{
  printf '%s\n' 'ip netns list'; ip netns list
  printf '%s\n' 'ip -br link'; ip -br link
  printf '%s\n' 'ip -br addr'; ip -br addr
  printf '%s\n' 'ip -4 route'; ip -4 route
  printf '%s\n' 'Goal001 server route'; ip -n "$SERVER_NS" route
  printf '%s\n' 'Goal001 server ip_forward'; printf '%s\n' "$forward_before"
  printf '%s\n' 'VPP show interface'; vpp_cli 'show interface'
} >"$REMOTE_BEFORE"
printf '%s\n' "$forward_before" >"$REMOTE_MARKER"

ip netns add "$REMOTE_NS" || die "创建 namespace $REMOTE_NS 失败"
ip link add "$ROUTER_IF" type veth peer name "$REMOTE_IF" || die '创建 Goal 004 veth 失败'
ip link set "$ROUTER_IF" netns "$SERVER_NS"
ip link set "$REMOTE_IF" netns "$REMOTE_NS"
ip -n "$SERVER_NS" addr add "$ROUTER_ADDR" dev "$ROUTER_IF"
ip -n "$REMOTE_NS" addr add "$REMOTE_ADDR" dev "$REMOTE_IF"
ip -n "$REMOTE_NS" addr add "$REMOTE_BACKEND_ADDR" dev lo
ip -n "$SERVER_NS" link set "$ROUTER_IF" up
ip -n "$REMOTE_NS" link set lo up
ip -n "$REMOTE_NS" link set "$REMOTE_IF" up
ip -n "$REMOTE_NS" route replace default via "$REMOTE_NEXT_HOP" dev "$REMOTE_IF"
ip -n "$SERVER_NS" route replace "$REMOTE_BACKEND_ADDR" via 10.10.3.2 dev "$ROUTER_IF"
ip netns exec "$SERVER_NS" sysctl -qw net.ipv4.ip_forward=1
go run ./cmd/goal004-route add || die 'GoVPP 添加远端 backend 路由失败'
printf 'Goal 004 remote: %s/%s -> %s/%s (%s)\n' "$SERVER_NS" "$ROUTER_IF" "$REMOTE_NS" "$REMOTE_IF" "$REMOTE_BACKEND"
