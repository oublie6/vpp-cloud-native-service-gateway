#!/usr/bin/env bash
# 在独立 kind API server 与 Goal 001 TAP 拓扑上验证 watch -> GoVPP -> VPP -> packet。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh

kubectl_bin=${GOAL003_KUBECTL:-kubectl}
kubeconfig=${GOAL003_KUBECONFIG:-}
test_recovery=${GOAL003_TEST_RECOVERY:-false}
[[ -n "$kubeconfig" && -r "$kubeconfig" ]] || die '设置 GOAL003_KUBECONFIG 为隔离 kind 集群配置'
command -v "$kubectl_bin" >/dev/null || die "缺少 kubectl: $kubectl_bin"
[[ "$test_recovery" == true || "$test_recovery" == false ]] || die 'GOAL003_TEST_RECOVERY 只接受 true/false'
export KUBECONFIG=$kubeconfig

require_root
require_vpp
[[ ! -e "$MARKER" ]] || die '已有 Goal 001 拓扑；拒绝接管'
! ip netns list | grep -Eq '^(g001-client|g001-server)( |$)' || die '实验 namespace 已存在'
! vppctl -s "$CLI_SOCKET" show cnat translation | grep -Fq '198.19.' || die 'Goal 003 VIP 范围已有 CNAT 状态'
! "$kubectl_bin" get namespace vpp-goal003 >/dev/null 2>&1 || die '测试 namespace 已存在；拒绝接管'

before_route=$(ip -4 route show default)
management_if=$(ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[[ -n "$management_if" ]] || die '无法确定宿主管理接口'
before_management=$(ip -br addr show "$management_if")
agent_pid=
server_pid=
created=false
applied=false
agent_log=$(mktemp /tmp/goal003-agent.XXXXXX)
server_log=$(mktemp /tmp/goal003-server.XXXXXX)
agent_bin=$(mktemp /tmp/goal003-agent-bin.XXXXXX)
empty_snapshot=$(mktemp /tmp/goal003-empty.XXXXXX)
printf '[]\n' >"$empty_snapshot"

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$agent_pid" ]]; then kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true; fi
  if [[ "$applied" == true ]]; then "$kubectl_bin" delete namespace vpp-goal003 --wait=true --timeout=60s || status=1; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ ! -S "$CLI_SOCKET" ]]; then scripts/goal001/start-vpp.sh || status=1; fi
  if [[ "$created" == true ]]; then
    go run ./cmd/goal003-reconcile -desired "$empty_snapshot" || status=1
    go run ./cmd/goal002-fib cleanup || status=1
    scripts/goal001/cleanup-topology.sh || status=1
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf 'host default route 发生变化\n' >&2; status=1; }
  [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '%s 地址/状态发生变化\n' "$management_if" >&2; status=1; }
  [[ ! -e "$MARKER" ]] || { printf 'Goal 001 ownership marker 未清理\n' >&2; status=1; }
  ! ip netns list | grep -Eq '^(g001-client|g001-server)( |$)' || { printf '实验 namespace 未清理\n' >&2; status=1; }
  ! vppctl -s "$CLI_SOCKET" show cnat translation | grep -Fq '198.19.' || { printf 'Goal 003 CNAT 未清理\n' >&2; status=1; }
  rm -f -- "$agent_log" "$server_log" "$agent_bin" "$empty_snapshot"
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
  grep -Fq 'backend server ready' "$server_log" && break
  kill -0 "$server_pid" 2>/dev/null || die "backend server 退出：$(cat "$server_log")"
  sleep 0.1
done
grep -Fq 'backend server ready' "$server_log" || die 'backend server 未就绪'

go build -o "$agent_bin" ./cmd/vpp-service-agent
"$agent_bin" -kubeconfig "$kubeconfig" -retry 1s >"$agent_log" 2>&1 &
agent_pid=$!
for attempt in {1..50}; do
  grep -Fq 'reconciled generation=' "$agent_log" && break
  kill -0 "$agent_pid" 2>/dev/null || die "controller 退出：$(cat "$agent_log")"
  sleep 0.2
done
grep -Fq 'reconciled generation=' "$agent_log" || die "controller 初始同步超时：$(cat "$agent_log")"

applied=true
"$kubectl_bin" apply -f deploy/kubernetes/goal003-test.yaml
for attempt in {1..40}; do
  count=$(vppctl -s "$CLI_SOCKET" show cnat translation | grep -Ec '^\[[0-9]+\] 198\.19\.0\.20;18080 (TCP|UDP)' || true)
  [[ "$count" == 2 ]] && break
  sleep 0.25
done
[[ "$count" == 2 ]] || die "Kubernetes 对象未生成两个 VPP translation：$(cat "$agent_log")"
printf 'Kubernetes -> VPP: TCP/UDP translation 均已创建\n'
vppctl -s "$CLI_SOCKET" clear trace
vppctl -s "$CLI_SOCKET" clear errors
vppctl -s "$CLI_SOCKET" trace add virtio-input 12
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --vip 198.19.0.20 --proto udp --flows 20 --base-port 30000 --require-both
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --vip 198.19.0.20 --proto tcp --flows 20 --base-port 31000 --require-both
trace=$(vppctl -s "$CLI_SOCKET" show trace)
grep -Fq 'ip4-cnat-tx' <<<"$trace" || die '未捕获 CNAT 成功 packet trace'
grep -Fq 'tap102-tx' <<<"$trace" || die 'trace 未进入 server TAP output'
printf '%s\n' "$trace" | awk '/^(Packet|[0-9][0-9]:.*(virtio-input|ethernet-input|ip4-input|ip4-lookup|ip4-cnat-tx|ip4-load-balance|ip4-rewrite|tap102-output|tap102-tx))/ { if (++printed <= 60) print }'
go run ./cmd/goal002-inspect
vppctl -s "$CLI_SOCKET" show runtime | grep -E 'virtio-input|ip4-cnat-tx|ip4-load-balance|ip4-rewrite'
vppctl -s "$CLI_SOCKET" show errors

"$kubectl_bin" patch endpointslice echo-manual -n vpp-goal003 --type=merge \
  -p '{"endpoints":[{"addresses":["10.10.2.2"],"conditions":{"ready":true}}]}'
for attempt in {1..40}; do
  translation=$(vppctl -s "$CLI_SOCKET" show cnat translation)
  [[ "$translation" != *'10.10.2.3;18080'* ]] && break
  sleep 0.25
done
[[ "$translation" != *'10.10.2.3;18080'* ]] || die 'EndpointSlice 缩容未更新 VPP backend'
ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --vip 198.19.0.20 --proto udp --flows 10 --base-port 32000 --expect-backend 10.10.2.2
printf 'EndpointSlice 缩容 -> VPP backend 与新 flow 已收敛\n'

if [[ "$test_recovery" == true ]]; then
  [[ $("$kubectl_bin" config current-context) == kind-goal003 ]] || die '恢复测试仅允许 kind-goal003 context'
  [[ $(docker inspect goal003-control-plane --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}') == goal003 ]] || die '控制平面容器不是本 Goal 的 kind 集群'

  kill "$agent_pid"
  wait "$agent_pid" || true
  agent_pid=
  : >"$agent_log"
  "$agent_bin" -kubeconfig "$kubeconfig" -retry 1s >"$agent_log" 2>&1 &
  agent_pid=$!
  for attempt in {1..50}; do
    grep -Fq 'services=2 changed=0' "$agent_log" && break
    kill -0 "$agent_pid" 2>/dev/null || die "controller 重启后退出：$(cat "$agent_log")"
    sleep 0.2
  done
  grep -Fq 'services=2 changed=0' "$agent_log" || die "controller 重启后未收敛：$(cat "$agent_log")"
  printf 'controller 重启 -> cache 全量同步、VPP 幂等复查通过\n'

  kill "$server_pid"
  wait "$server_pid" || true
  server_pid=
  go run ./cmd/goal002-fib cleanup
  scripts/goal001/cleanup-topology.sh
  created=false
  scripts/goal001/stop-vpp.sh
  sleep 2
  grep -Fq 'reconcile failed:' "$agent_log" || die 'VPP 停止期间未观察到 controller 失败重试'
  scripts/goal001/start-vpp.sh
  created=true
  scripts/goal001/setup-topology.sh
  go run ./cmd/goal002-fib setup
  ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
  ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
  ip -n "$SERVER_NS" addr add 10.10.2.3/24 dev "$SERVER_HOST_IF"
  ip netns exec "$SERVER_NS" python3 -u scripts/goal002/service_traffic.py server >"$server_log" 2>&1 &
  server_pid=$!
  for attempt in {1..50}; do
    grep -Fq 'backend server ready' "$server_log" && break
    kill -0 "$server_pid" 2>/dev/null || die "backend server 重启后退出：$(cat "$server_log")"
    sleep 0.1
  done
  grep -Fq 'backend server ready' "$server_log" || die 'backend server 重启后未就绪'
  for attempt in {1..40}; do
    count=$(vppctl -s "$CLI_SOCKET" show cnat translation | grep -Ec '^\[[0-9]+\] 198\.19\.0\.20;18080 (TCP|UDP)' || true)
    [[ "$count" == 2 ]] && break
    sleep 0.25
  done
  [[ "$count" == 2 ]] || die "VPP 重启后 controller 未重建 translation：$(cat "$agent_log")"
  ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --vip 198.19.0.20 --proto udp --flows 5 --base-port 33000 --expect-backend 10.10.2.2
  printf 'VPP 重启 / GoVPP reconnect -> translation 与 packet 已恢复\n'

  docker restart goal003-control-plane
  for attempt in {1..60}; do
    "$kubectl_bin" get --raw /readyz >/dev/null 2>&1 && break
    sleep 1
  done
  "$kubectl_bin" get --raw /readyz >/dev/null || die 'kind API server 重启后未恢复'
  "$kubectl_bin" patch endpointslice echo-manual -n vpp-goal003 --type=merge \
    -p '{"endpoints":[{"addresses":["10.10.2.2"],"conditions":{"ready":true}},{"addresses":["10.10.2.3"],"conditions":{"ready":true}}]}'
  for attempt in {1..40}; do
    translation=$(vppctl -s "$CLI_SOCKET" show cnat translation)
    [[ "$translation" == *'10.10.2.3;18080'* ]] && break
    sleep 0.25
  done
  [[ "$translation" == *'10.10.2.3;18080'* ]] || die "API server 重启后 EndpointSlice watch 未收敛：$(cat "$agent_log")"
  ip netns exec "$CLIENT_NS" python3 scripts/goal002/service_traffic.py client --vip 198.19.0.20 --proto udp --flows 20 --base-port 34000 --require-both
  printf 'Kubernetes API server 重启 / watch reconnect -> backend 扩容与 packet 已恢复\n'
fi

"$kubectl_bin" delete service echo -n vpp-goal003
for attempt in {1..40}; do
  count=$(vppctl -s "$CLI_SOCKET" show cnat translation | grep -Ec '^\[[0-9]+\] 198\.19\.0\.20;18080 (TCP|UDP)' || true)
  [[ "$count" == 0 ]] && break
  sleep 0.25
done
[[ "$count" == 0 ]] || die "Service 删除后 translation 仍存在：$(cat "$agent_log")"
printf 'Service 删除 -> VPP translation 清除\n'
cat "$agent_log"
