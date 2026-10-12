#!/usr/bin/env bash
# 独立 kind API server + 双逻辑节点软件拓扑的 local/remote Service E2E。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal004/remote-common.sh

kubectl_bin=${GOAL004_KUBECTL:-kubectl}
kubeconfig=${GOAL004_KUBECONFIG:-}
[[ -n "$kubeconfig" && -r "$kubeconfig" ]] || die '设置 GOAL004_KUBECONFIG 为隔离 kind 集群配置'
command -v "$kubectl_bin" >/dev/null || die "缺少 kubectl: $kubectl_bin"
export KUBECONFIG=$kubeconfig

require_root
require_vpp
[[ ! -e "$MARKER" && ! -e "$REMOTE_MARKER" ]] || die '实验拓扑 marker 已存在，拒绝接管'
! ip netns list | grep -Eq '^(g001-client|g001-server|g004-remote)( |$)' || die '实验 namespace 已存在'
inspect=$(go run ./cmd/goal002-inspect)
grep -Fq 'CNAT translations=0 sessions=0' <<<"$inspect" || die 'VPP 仍有 CNAT state，拒绝开始'
[[ $("$kubectl_bin" config current-context) == kind-goal004 ]] || die '仅允许 kind-goal004 context'
! "$kubectl_bin" get namespace vpp-goal004 >/dev/null 2>&1 || die '实验 namespace 已存在'

before_route=$(ip -4 route show default)
management_if=$(ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[[ -n "$management_if" ]] || die '无法确定宿主管理接口'
before_management=$(ip -br addr show "$management_if")
before_hugepages=$(sysctl -n vm.nr_hugepages)
agent_pid=
local_pid=
remote_pid=
created=false
applied=false
agent_bin=$(mktemp /tmp/goal004-agent-bin.XXXXXX)
agent_log=$(mktemp /tmp/goal004-agent.XXXXXX)
local_log=$(mktemp /tmp/goal004-local.XXXXXX)
remote_log=$(mktemp /tmp/goal004-remote.XXXXXX)
flow_log=$(mktemp /tmp/goal004-flow.XXXXXX)
empty_snapshot=$(mktemp /tmp/goal004-empty.XXXXXX)
printf '[]\n' >"$empty_snapshot"

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$agent_pid" ]]; then kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true; fi
  if [[ "$applied" == true ]]; then "$kubectl_bin" delete namespace vpp-goal004 --wait=true --timeout=60s || status=1; fi
  if [[ -n "$local_pid" ]]; then kill "$local_pid" 2>/dev/null || true; wait "$local_pid" 2>/dev/null || true; fi
  if [[ -n "$remote_pid" ]]; then kill "$remote_pid" 2>/dev/null || true; wait "$remote_pid" 2>/dev/null || true; fi
  if [[ ! -S "$CLI_SOCKET" ]]; then scripts/goal001/start-vpp.sh || status=1; fi
  if [[ "$created" == true ]]; then
    go run ./cmd/goal003-reconcile -desired "$empty_snapshot" || status=1
    go run ./cmd/goal004-purge || status=1
    if [[ -e "$REMOTE_MARKER" ]]; then scripts/goal004/cleanup-remote.sh || status=1; fi
    go run ./cmd/goal002-fib cleanup || status=1
    scripts/goal001/cleanup-topology.sh || status=1
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf '宿主默认路由发生变化\n' >&2; status=1; }
  [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '%s 地址/状态发生变化\n' "$management_if" >&2; status=1; }
  [[ $(sysctl -n vm.nr_hugepages) == "$before_hugepages" ]] || { printf 'HugePages 配置发生变化\n' >&2; status=1; }
  ! ip netns list | grep -Eq '^(g001-client|g001-server|g004-remote)( |$)' || { printf '实验 namespace 未清理\n' >&2; status=1; }
  [[ ! -e "$MARKER" && ! -e "$REMOTE_MARKER" ]] || { printf '实验 marker 未清理\n' >&2; status=1; }
  rm -f -- "$agent_bin" "$agent_log" "$local_log" "$remote_log" "$flow_log" "$empty_snapshot"
  exit "$status"
}
trap cleanup EXIT

created=true
scripts/goal001/setup-topology.sh
go run ./cmd/goal002-fib setup
ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
scripts/goal004/setup-remote.sh
ip netns exec "$SERVER_NS" python3 -u scripts/goal004/traffic.py server --bind 10.10.2.2 >"$local_log" 2>&1 &
local_pid=$!
ip netns exec "$REMOTE_NS" python3 -u scripts/goal004/traffic.py server --bind 10.10.4.2 >"$remote_log" 2>&1 &
remote_pid=$!
for attempt in {1..50}; do
  grep -Fq 'backend server ready' "$local_log" && grep -Fq 'backend server ready' "$remote_log" && break
  kill -0 "$local_pid" 2>/dev/null || die "local backend 退出：$(cat "$local_log")"
  kill -0 "$remote_pid" 2>/dev/null || die "remote backend 退出：$(cat "$remote_log")"
  sleep 0.1
done
grep -Fq 'backend server ready' "$local_log" || die 'local backend 未就绪'
grep -Fq 'backend server ready' "$remote_log" || die 'remote backend 未就绪'

go build -o "$agent_bin" ./cmd/vpp-service-agent
"$agent_bin" -kubeconfig "$kubeconfig" -retry 1s -metrics-listen 127.0.0.1:18084 >"$agent_log" 2>&1 &
agent_pid=$!
for attempt in {1..50}; do
  grep -Fq 'reconciled generation=' "$agent_log" && break
  kill -0 "$agent_pid" 2>/dev/null || die "controller 退出：$(cat "$agent_log")"
  sleep 0.2
done
grep -Fq 'reconciled generation=' "$agent_log" || die "controller 初始同步超时：$(cat "$agent_log")"

applied=true
"$kubectl_bin" apply -f deploy/kubernetes/goal004-test.yaml
for attempt in {1..40}; do
  translation=$(vppctl -s "$CLI_SOCKET" show cnat translation)
  count=$(grep -Ec '^\[[0-9]+\] 198\.19\.0\.20;18080 (TCP|UDP)' <<<"$translation" || true)
  [[ "$count" == 2 && "$translation" == *'10.10.4.2;18080'* ]] && break
  sleep 0.25
done
[[ "$count" == 2 && "$translation" == *'10.10.4.2;18080'* ]] || die "Kubernetes 未创建 local/remote translation：$(cat "$agent_log")"
go run ./cmd/goal004-route inspect
ip netns exec "$CLIENT_NS" ping -c 3 -W 1 "$REMOTE_BACKEND"

vppctl -s "$CLI_SOCKET" clear trace
vppctl -s "$CLI_SOCKET" clear errors
vppctl -s "$CLI_SOCKET" trace add virtio-input 30
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 20 --base-port 35000 --require-both | tee "$flow_log"
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto tcp --flows 20 --base-port 36000 --require-both
trace=$(vppctl -s "$CLI_SOCKET" show trace)
grep -Fq '10.10.4.2;18080' <<<"$trace" || die 'trace 未观察到远端 backend session'
grep -Fq 'tap102-tx' <<<"$trace" || die 'trace 未观察到 server TAP output'
printf '%s\n' "$trace" | awk '/^(Packet|[0-9][0-9]:.*(virtio-input|ethernet-input|ip4-input|ip4-lookup|ip4-cnat-tx|ip4-load-balance|ip4-rewrite|tap102-output|tap102-tx))|session:\[/ { if (++printed <= 55) print }'
vppctl -s "$CLI_SOCKET" show ip fib "$REMOTE_BACKEND_ADDR"
vppctl -s "$CLI_SOCKET" show ip neighbors
vppctl -s "$CLI_SOCKET" show adj
go run ./cmd/goal002-inspect
vppctl -s "$CLI_SOCKET" show errors
curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:18084/metrics
curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:18084/status

remote_index=$(awk '$1 == "udp" && $2 == "flow" && $4 == "backend" && $5 == "10.10.4.2" { print $3; exit }' "$flow_log")
[[ "$remote_index" =~ ^[0-9]+$ ]] || die '没有远端 UDP flow 用于故障测试'
old_port=$((35000 + remote_index))
ip -n "$REMOTE_NS" link set "$REMOTE_IF" down
if ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 1 --base-port "$old_port" --expect-backend 10.10.4.2 >"$flow_log" 2>&1; then
  die '远端链路 down 后旧远端 UDP session 仍成功'
fi
grep -Eq 'timed out|Network is unreachable' "$flow_log" || die "故障流量失败原因异常：$(cat "$flow_log")"
printf '远端链路 down -> 旧远端 UDP session 失败：%s\n' "$(tail -1 "$flow_log")"
"$kubectl_bin" patch endpointslice echo-two-node-manual -n vpp-goal004 --type=merge \
  -p '{"endpoints":[{"addresses":["10.10.2.2"],"conditions":{"ready":true}},{"addresses":["10.10.4.2"],"conditions":{"ready":false}}]}'
for attempt in {1..40}; do
  translation=$(vppctl -s "$CLI_SOCKET" show cnat translation)
  [[ "$translation" != *'10.10.4.2;18080'* ]] && break
  sleep 0.25
done
[[ "$translation" != *'10.10.4.2;18080'* ]] || die 'EndpointSlice ready=false 后远端仍在 VPP translation'
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 10 --base-port 39000 --expect-backend 10.10.2.2 --quiet
ip -n "$REMOTE_NS" link set "$REMOTE_IF" up
ip -n "$REMOTE_NS" route replace default via "$REMOTE_NEXT_HOP" dev "$REMOTE_IF"
for attempt in {1..5}; do
  if ip netns exec "$CLIENT_NS" ping -c 1 -W 1 "$REMOTE_BACKEND" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
ip netns exec "$CLIENT_NS" ping -c 1 -W 1 "$REMOTE_BACKEND" >/dev/null || die '远端链路恢复后 L3/ARP 未恢复'
"$kubectl_bin" patch endpointslice echo-two-node-manual -n vpp-goal004 --type=merge \
  -p '{"endpoints":[{"addresses":["10.10.2.2"],"conditions":{"ready":true}},{"addresses":["10.10.4.2"],"conditions":{"ready":true}}]}'
for attempt in {1..40}; do
  translation=$(vppctl -s "$CLI_SOCKET" show cnat translation)
  [[ "$translation" == *'10.10.4.2;18080'* ]] && break
  sleep 0.25
done
[[ "$translation" == *'10.10.4.2;18080'* ]] || die '远端恢复后 VPP translation 未扩容'
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 20 --base-port 40000 --require-both --quiet
printf '远端链路故障、EndpointSlice 缩容与恢复已验证\n'

printf '远端链路故障后的 VPP error counters：\n'
vppctl -s "$CLI_SOCKET" show errors
kill "$local_pid"
wait "$local_pid" || true
local_pid=
kill "$remote_pid"
wait "$remote_pid" || true
remote_pid=
kill "$agent_pid"
wait "$agent_pid" || true
agent_pid=
go run ./cmd/goal003-reconcile -desired "$empty_snapshot"
go run ./cmd/goal004-purge
scripts/goal004/cleanup-remote.sh
go run ./cmd/goal002-fib cleanup
scripts/goal001/cleanup-topology.sh
created=false
scripts/goal001/stop-vpp.sh
"$agent_bin" -kubeconfig "$kubeconfig" -retry 1s -metrics-listen 127.0.0.1:18084 >>"$agent_log" 2>&1 &
agent_pid=$!
sleep 2
kill -0 "$agent_pid" 2>/dev/null || die "VPP 停止期间 controller 退出：$(cat "$agent_log")"
metrics=$(curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:18084/metrics)
grep -Eq '^vpp_gateway_reconcile_failures_total [1-9][0-9]*$' <<<"$metrics" || die 'VPP 停止时 controller 未记录失败重试'
scripts/goal001/start-vpp.sh
created=true
scripts/goal001/setup-topology.sh
go run ./cmd/goal002-fib setup
ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
scripts/goal004/setup-remote.sh
: >"$local_log"
: >"$remote_log"
ip netns exec "$SERVER_NS" python3 -u scripts/goal004/traffic.py server --bind 10.10.2.2 >"$local_log" 2>&1 &
local_pid=$!
ip netns exec "$REMOTE_NS" python3 -u scripts/goal004/traffic.py server --bind 10.10.4.2 >"$remote_log" 2>&1 &
remote_pid=$!
for attempt in {1..50}; do
  grep -Fq 'backend server ready' "$local_log" && grep -Fq 'backend server ready' "$remote_log" && break
  kill -0 "$local_pid" 2>/dev/null || die "重启后 local backend 退出：$(cat "$local_log")"
  kill -0 "$remote_pid" 2>/dev/null || die "重启后 remote backend 退出：$(cat "$remote_log")"
  sleep 0.1
done
grep -Fq 'backend server ready' "$local_log" || die '重启后 local backend 未就绪'
grep -Fq 'backend server ready' "$remote_log" || die '重启后 remote backend 未就绪'
for attempt in {1..40}; do
  translation=$(vppctl -s "$CLI_SOCKET" show cnat translation)
  count=$(grep -Ec '^\[[0-9]+\] 198\.19\.0\.20;18080 (TCP|UDP)' <<<"$translation" || true)
  [[ "$count" == 2 && "$translation" == *'10.10.4.2;18080'* ]] && break
  sleep 0.25
done
[[ "$count" == 2 && "$translation" == *'10.10.4.2;18080'* ]] || die "VPP 重启后 controller 未恢复远端 translation：$(cat "$agent_log")"
ip netns exec "$CLIENT_NS" ping -c 2 -W 1 "$REMOTE_BACKEND"
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 20 --base-port 41000 --require-both --quiet
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto tcp --flows 20 --base-port 42000 --require-both --quiet
printf 'VPP/GoVPP 重启后 local/remote 双 backend packet 恢复\n'
grep -F 'reconcile failed:' "$agent_log" | tail -5
curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:18084/metrics

vppctl -s "$CLI_SOCKET" clear errors
printf 'software measurement metadata: TCP/UDP, 100 flows each, payload=128B, target_offered=200flows/s, Linux TAP/veth\n'
lscpu | grep -E '^(CPU\(s\)|Model name|Socket\(s\)|NUMA node\(s\)):'
printf 'measurement before Stats API counters:\n'
go run ./cmd/goal002-inspect
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 100 --base-port 50000 --payload-size 128 --interval-us 5000 --require-both --quiet
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto tcp --flows 100 --base-port 51000 --payload-size 128 --interval-us 5000 --require-both --quiet
printf 'measurement after Stats API counters:\n'
go run ./cmd/goal002-inspect
vppctl -s "$CLI_SOCKET" show runtime | grep -E 'virtio-input|ip4-cnat-tx|ip4-load-balance|ip4-rewrite'
vppctl -s "$CLI_SOCKET" show threads
vppctl -s "$CLI_SOCKET" show errors
curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:18084/metrics
printf '\nGoal 004 两逻辑节点 E2E、故障收敛与有界软件测量完成\n'
