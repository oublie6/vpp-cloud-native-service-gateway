#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/remote-common.sh"
require_root
require_vpp

if [[ ! -e "$REMOTE_MARKER" ]]; then
  ! ip netns list | grep -Eq "^${REMOTE_NS}( |$)" || die "$REMOTE_NS 存在但无 Goal 004 marker，拒绝删除"
  if ip netns list | grep -Eq "^${SERVER_NS}( |$)"; then
    ! ip netns exec "$SERVER_NS" ip link show "$ROUTER_IF" >/dev/null 2>&1 || die "$ROUTER_IF 存在但无 marker，拒绝删除"
  fi
  printf 'Goal 004 远端拓扑已清理\n'
  exit 0
fi
require_goal001_topology
[[ -f "$REMOTE_MARKER" ]] || die 'Goal 004 marker 不是普通文件'
forward_before=$(<"$REMOTE_MARKER")
[[ "$forward_before" =~ ^[01]$ ]] || die 'Goal 004 marker 中 ip_forward 原值无效'
go run ./cmd/goal004-route del || die 'GoVPP 删除远端 backend 路由失败'
if ip netns list | grep -Eq "^${REMOTE_NS}( |$)"; then
  ip netns del "$REMOTE_NS" || die "删除 $REMOTE_NS 失败"
fi
if ip netns exec "$SERVER_NS" ip link show "$ROUTER_IF" >/dev/null 2>&1; then
  ip -n "$SERVER_NS" link del "$ROUTER_IF" || die "删除 $ROUTER_IF 失败"
fi
ip netns exec "$SERVER_NS" sysctl -qw "net.ipv4.ip_forward=$forward_before"
rm -f -- "$REMOTE_MARKER"
! ip netns list | grep -Eq "^${REMOTE_NS}( |$)" || die "$REMOTE_NS 未删除"
! ip netns exec "$SERVER_NS" ip link show "$ROUTER_IF" >/dev/null 2>&1 || die "$ROUTER_IF 未删除"
printf 'Goal 004 远端拓扑已清理；原始状态：%s\n' "$REMOTE_BEFORE"
