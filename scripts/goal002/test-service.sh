#!/usr/bin/env bash
# 从干净的 Goal 001 TAP 环境验证 GoVPP CNAT TCP/UDP VIP、多 backend 和动态更新。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh

require_root
require_vpp
[[ ! -e "$MARKER" ]] || die '已有 Goal 001 拓扑；拒绝接管或清理预存资源'
! ip netns list | grep -Eq '^(g001-client|g001-server)( |$)' || die 'Goal 001 namespace 已存在'
! vppctl -s "$CLI_SOCKET" show interface | grep -Eq '(^|[[:space:]])tap10[12]([[:space:]]|$)' || die 'Goal 001 TAP 已存在'
inspect_output=$(go run ./cmd/goal002-inspect) || die '无法读取独立 VPP 实例的 API 状态'
grep -Fq 'CNAT translations=0 sessions=0' <<<"$inspect_output" || die 'CNAT 已有状态；拒绝全局 session purge'

before_route=$(ip -4 route show default)
management_if=$(ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[[ -n "$management_if" ]] || die '无法确定宿主管理接口'
before_management=$(ip -br addr show "$management_if")
server_pid=
created=false
traffic_log=$(mktemp /tmp/goal002-traffic.XXXXXX)
server_log=$(mktemp /tmp/goal002-server.XXXXXX)

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ "$created" == true ]]; then
    go run ./cmd/goal002-service -proto udp delete || status=1
    go run ./cmd/goal002-service -proto tcp delete || status=1
    go run ./cmd/goal002-service purge || status=1
    go run ./cmd/goal002-fib cleanup || status=1
    scripts/goal001/cleanup-topology.sh || status=1
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf 'host default route 发生变化\n' >&2; status=1; }
  [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '%s 地址/状态发生变化\n' "$management_if" >&2; status=1; }
  [[ ! -e "$MARKER" ]] || { printf 'ownership marker 仍存在\n' >&2; status=1; }
  ! ip netns list | grep -Eq '^(g001-client|g001-server)( |$)' || { printf 'Goal 001 namespace 未清理\n' >&2; status=1; }
  ! vppctl -s "$CLI_SOCKET" show interface | grep -Eq '(^|[[:space:]])tap10[12]([[:space:]]|$)' || { printf 'Goal 001 TAP 未清理\n' >&2; status=1; }
  rm -f -- "$traffic_log" "$server_log"
  exit "$status"
}
trap cleanup EXIT

created=true
scripts/goal001/setup-topology.sh
go run ./cmd/goal002-fib setup
ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
ip -n "$SERVER_NS" addr add 10.10.2.3/24 dev "$SERVER_HOST_IF"

ip netns exec "$SERVER_NS" python3 -u scripts/goal002/service_traffic.py server >"$server_log" 2>&1 &
server_pid=$!
for attempt in {1..50}; do
  if grep -Fq 'backend server ready' "$server_log"; then break; fi
  kill -0 "$server_pid" 2>/dev/null || die "backend server 退出：$(cat "$server_log")"
  sleep 0.1
done
grep -Fq 'backend server ready' "$server_log" || die 'backend server 未就绪'

go run ./cmd/goal002-service -proto udp apply
go run ./cmd/goal002-service -proto tcp apply
vppctl -s "$CLI_SOCKET" show ip fib 198.18.0.10/32 | grep -F 'cnat-client'

ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto udp --flows 20 --base-port 20000 --repeats 2 --require-both | tee "$traffic_log"
old_index=$(awk '$1 == "udp" && $2 == "flow" && $4 == "backend" && $5 == "10.10.2.3" { print $3; exit }' "$traffic_log")
[[ "$old_index" =~ ^[0-9]+$ ]] || die '未找到 .3 backend 的旧 UDP flow'
old_port=$((20000 + old_index))
sessions=$(go run ./cmd/goal002-service sessions | awk -F= '/^sessions=/ { print $2 }')
[[ "$sessions" =~ ^[0-9]+$ && "$sessions" -ge 2 ]] || die '未观察到 CNAT 正反向 session'
printf 'UDP 正反向 session 数：%s；旧 .3 flow 源端口：%s\n' "$sessions" "$old_port"

go run ./cmd/goal002-service -proto udp -backends 10.10.2.2 apply
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto udp --flows 1 --base-port "$old_port" --repeats 2 --expect-backend 10.10.2.3
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto udp --flows 10 --base-port 22000 --expect-backend 10.10.2.2
go run ./cmd/goal002-service -proto udp apply
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto udp --flows 20 --base-port 23000 --require-both
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto tcp --flows 20 --base-port 21000 --require-both

vppctl -s "$CLI_SOCKET" clear trace
vppctl -s "$CLI_SOCKET" clear errors
vppctl -s "$CLI_SOCKET" trace add virtio-input 12
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto udp --flows 4 --base-port 25000
vppctl -s "$CLI_SOCKET" show trace | awk '
  /^Packet [12][[:space:]]*$/ { active = 1; print; next }
  /^Packet [0-9]+/ { active = 0 }
  active && (/^[0-9][0-9]:/ || /created session/ || /found session/ || /session:\[/) { print }
'
go run ./cmd/goal002-inspect
vppctl -s "$CLI_SOCKET" show runtime | grep -E 'virtio-input|ip4-cnat-tx|ip4-load-balance|ip4-rewrite'
vppctl -s "$CLI_SOCKET" show errors

go run ./cmd/goal002-service -proto udp delete
go run ./cmd/goal002-service -proto tcp delete
go run ./cmd/goal002-service purge
go run ./cmd/goal002-inspect | grep -F 'CNAT translations=0 sessions=0'
if ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto udp --flows 1 --base-port 26000 >"$traffic_log" 2>&1; then
  die '删除 Service 后新 UDP flow 仍成功'
fi
grep -Fq 'timed out' "$traffic_log" || die "删除后的失败原因不是 timeout：$(cat "$traffic_log")"
if ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --proto tcp --flows 1 --base-port 27000 >"$traffic_log" 2>&1; then
  die '删除 Service 后新 TCP flow 仍成功'
fi
grep -Eq 'timed out|No route to host|Network is unreachable' "$traffic_log" || die "删除后的 TCP 失败原因异常：$(cat "$traffic_log")"
printf '删除 Service 后新 UDP/TCP flow 均失败；Goal 002 CNAT E2E 验证通过\n'
