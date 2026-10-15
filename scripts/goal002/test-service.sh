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
client_capture_pid=
server_capture_pid=
created=false
input_feature_enabled=false
traffic_log=$(mktemp /tmp/goal002-traffic.XXXXXX)
server_log=$(mktemp /tmp/goal002-server.XXXXXX)

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "${GOAL006_DIAGNOSTICS_DIR:-}" && "$created" == true ]]; then
    # 仅用于 Goal006 隔离复现；在删除 session/TAP 前保留失败瞬间的状态。
    vppctl -s "$CLI_SOCKET" show trace > "$GOAL006_DIAGNOSTICS_DIR/trace.txt" 2>&1 || true
    vppctl -s "$CLI_SOCKET" show ip fib 10.10.1.2/32 > "$GOAL006_DIAGNOSTICS_DIR/client-fib.txt" 2>&1 || true
    vppctl -s "$CLI_SOCKET" show cnat session > "$GOAL006_DIAGNOSTICS_DIR/sessions.txt" 2>&1 || true
    vppctl -s "$CLI_SOCKET" show interface rx-placement > "$GOAL006_DIAGNOSTICS_DIR/rx-placement.txt" 2>&1 || true
    vppctl -s "$CLI_SOCKET" show errors > "$GOAL006_DIAGNOSTICS_DIR/errors.txt" 2>&1 || true
    go run ./cmd/goal002-inspect > "$GOAL006_DIAGNOSTICS_DIR/api-state.txt" 2>&1 || true
    cp "$server_log" "$GOAL006_DIAGNOSTICS_DIR/backend.log" 2>/dev/null || true
  fi
  for capture_pid in "$client_capture_pid" "$server_capture_pid"; do
    if [[ -n "$capture_pid" ]]; then
      kill "$capture_pid" 2>/dev/null || true
      wait "$capture_pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ "$input_feature_enabled" == true ]]; then
    go run ./cmd/goal006-feature disable || status=1
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
if [[ -n "${GOAL002_RX_WORKER:-}" ]]; then
  [[ "$GOAL002_RX_WORKER" =~ ^[0-9]+$ ]] || die 'GOAL002_RX_WORKER 必须是 worker 编号'
  server_worker=${GOAL002_SERVER_RX_WORKER:-$GOAL002_RX_WORKER}
  [[ "$server_worker" =~ ^[0-9]+$ ]] || die 'GOAL002_SERVER_RX_WORKER 必须是 worker 编号'
  placement_matches() {
    local iface=$1 worker=$2
    vppctl -s "$CLI_SOCKET" show interface rx-placement | awk -v iface="$iface" -v wanted="vpp_wk_$worker" '
      /^Thread / { current=$3; gsub(/[():\r]/, "", current) }
      $1 == iface && $2 == "queue" { found=1; if (current == wanted) matched=1 }
      END { exit !(found && matched) }
    '
  }
  if [[ "${GOAL006_REQUIRE_AUTO_RX:-false}" == true ]]; then
    # 本机 VPP 24.10 偶发在 TAP RX placement 动态迁移时触发 worker barrier abort；先检查自动分配。
    vppctl -s "$CLI_SOCKET" show interface rx-placement
    placement_matches tap101 "$GOAL002_RX_WORKER" || die 'tap101 自动 RX worker 与预期不同'
    placement_matches tap102 "$server_worker" || die 'tap102 自动 RX worker 与预期不同'
  else
    if ! placement_matches tap101 "$GOAL002_RX_WORKER"; then
      vppctl -s "$CLI_SOCKET" set interface rx-placement tap101 queue 0 worker "$GOAL002_RX_WORKER"
    fi
    if ! placement_matches tap102 "$server_worker"; then
      vppctl -s "$CLI_SOCKET" set interface rx-placement tap102 queue 0 worker "$server_worker"
    fi
  fi
  vppctl -s "$CLI_SOCKET" show interface rx-placement
fi
go run ./cmd/goal002-fib setup
ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
ip -n "$SERVER_NS" addr add 10.10.2.3/24 dev "$SERVER_HOST_IF"
if [[ "${GOAL006_ENABLE_INPUT_FEATURE:-false}" == true ]]; then
  go run ./cmd/goal006-feature enable
  input_feature_enabled=true
  vppctl -s "$CLI_SOCKET" show interface features tap102 | grep -F 'cnat-input-ip4'
fi

# 双 worker 下首个 UDP reply 可能在邻居解析时丢失；先验证并完成双向 ARP。
for backend in 10.10.2.2 10.10.2.3; do
  ip netns exec "$CLIENT_NS" ping -n -c 2 -W 2 "$backend" >/dev/null || die "预热 $backend 邻居失败"
done
ip netns exec "$SERVER_NS" ping -n -c 2 -W 2 "${CLIENT_ADDR%/*}" >/dev/null || die '预热 client 邻居失败'

ip netns exec "$SERVER_NS" python3 -u scripts/goal002/service_traffic.py server --reply-delay "${GOAL002_SERVER_REPLY_DELAY:-0}" >"$server_log" 2>&1 &
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

if [[ -n "${GOAL006_DIAGNOSTICS_DIR:-}" ]]; then
  [[ -d "$GOAL006_DIAGNOSTICS_DIR" && -O "$GOAL006_DIAGNOSTICS_DIR" ]] || die 'Goal006 diagnostics 目录不可用'
  vppctl -s "$CLI_SOCKET" clear trace
  vppctl -s "$CLI_SOCKET" clear errors
  vppctl -s "$CLI_SOCKET" trace add virtio-input 32
  ip netns exec "$CLIENT_NS" tcpdump -i "$CLIENT_HOST_IF" -nn -U -s 128 \
    -w "$GOAL006_DIAGNOSTICS_DIR/client-tap.pcap" 'udp and port 18080' \
    > "$GOAL006_DIAGNOSTICS_DIR/client-tcpdump.log" 2>&1 &
  client_capture_pid=$!
  ip netns exec "$SERVER_NS" tcpdump -i "$SERVER_HOST_IF" -nn -U -s 128 \
    -w "$GOAL006_DIAGNOSTICS_DIR/server-tap.pcap" 'udp and port 18080' \
    > "$GOAL006_DIAGNOSTICS_DIR/server-tcpdump.log" 2>&1 &
  server_capture_pid=$!
  for capture_log in client-tcpdump.log server-tcpdump.log; do
    for attempt in {1..50}; do
      grep -Fq 'listening on' "$GOAL006_DIAGNOSTICS_DIR/$capture_log" && break
      sleep 0.05
    done
    grep -Fq 'listening on' "$GOAL006_DIAGNOSTICS_DIR/$capture_log" || die "tcpdump 未就绪：$capture_log"
  done
fi

if [[ "${GOAL006_FIRST_REPLY_REGRESSION:-false}" == true ]]; then
  for round in 1 2 3; do
    base_port=$((30000 + round * 1000))
    ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client \
      --proto udp --flows 100 --base-port "$base_port" --repeats 1 --require-both \
      > "$traffic_log"
    [[ $(grep -c '^udp flow ' "$traffic_log") -eq 100 ]] || die "第 $round 轮 UDP flow 数不足"
    tail -n 1 "$traffic_log"
    printf 'Goal006 zero-delay UDP first reply: round=%d flows=100 VIP peers=100\n' "$round"
  done
fi

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
vppctl -s "$CLI_SOCKET" show interface rx-placement
vppctl -s "$CLI_SOCKET" show threads
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
