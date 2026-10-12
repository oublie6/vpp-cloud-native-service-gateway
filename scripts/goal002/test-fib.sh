#!/usr/bin/env bash
# 从干净环境验证 GoVPP 接口地址、FIB add/delete、Stats 和 host cleanup。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh

require_root
require_vpp
[[ ! -e "$MARKER" ]] || die '已有 Goal 001 拓扑；请先处理，避免本脚本清理预存资源'
! ip netns list | grep -Eq '^(g001-client|g001-server)( |$)' || die 'Goal 001 namespace 已存在'
! vppctl -s "$CLI_SOCKET" show interface | grep -Eq '(^|[[:space:]])tap10[12]([[:space:]]|$)' || die 'Goal 001 TAP 已存在'

before_route=$(ip -4 route show default)
management_if=$(ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[[ -n "$management_if" ]] || die '无法确定宿主管理接口'
before_management=$(ip -br addr show "$management_if")
created=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$created" == true ]]; then
    go run ./cmd/goal002-fib route-del || true
    go run ./cmd/goal002-fib cleanup || true
    scripts/goal001/cleanup-topology.sh || status=1
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf 'host default route 发生变化\n' >&2; status=1; }
  [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '%s 地址/状态发生变化\n' "$management_if" >&2; status=1; }
  [[ ! -e "$MARKER" ]] || { printf 'Goal 001 ownership marker 仍存在\n' >&2; status=1; }
  ! ip netns list | grep -Eq '^(g001-client|g001-server)( |$)' || { printf 'Goal 001 namespace 未清理\n' >&2; status=1; }
  ! vppctl -s "$CLI_SOCKET" show interface | grep -Eq '(^|[[:space:]])tap10[12]([[:space:]]|$)' || { printf 'Goal 001 VPP TAP 未清理\n' >&2; status=1; }
  exit "$status"
}
trap cleanup EXIT

created=true
scripts/goal001/setup-topology.sh
go run ./cmd/goal002-fib setup
go run ./cmd/goal002-fib setup
ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
ip -n "$SERVER_NS" addr add 198.18.0.3/32 dev lo

go run ./cmd/goal002-inspect
go run ./cmd/goal002-fib route-add
go run ./cmd/goal002-fib route-add
vppctl -s "$CLI_SOCKET" show ip fib 198.18.0.3/32 | grep -F 'via 10.10.2.2 tap102'
ip netns exec "$CLIENT_NS" ping -c 3 -W 1 198.18.0.3
go run ./cmd/goal002-inspect

go run ./cmd/goal002-fib route-del
go run ./cmd/goal002-fib route-del
if ip netns exec "$CLIENT_NS" ping -c 2 -W 1 198.18.0.3; then
  die '删除路由后 packet 仍可到达实验目的地址'
fi
printf 'Goal 002 FIB add/delete 与 packet 验证通过\n'
