#!/usr/bin/env bash
# 现有双 Ready 节点：Kubernetes EndpointSlice -> GoVPP CNAT -> 真实远端 Pod TCP。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh
source /etc/goal004-worker-tcp.env

remote_host=${GOAL004_REMOTE_HOST:?}
askpass=${GOAL004_SSH_ASKPASS:?}
known_hosts=${GOAL004_KNOWN_HOSTS:?}
remote_user=${GOAL004_REMOTE_USER:-root}
remote_node=${GOAL004_REMOTE_NODE_NAME:-ser730417996259}
local_node=${GOAL004_LOCAL_NODE_NAME:-hk-worker}
namespace=goal004-pod-backend
host_if=g004podh
ns_if=g004podn
host_ip=10.200.4.1
ns_ip=10.200.4.2
route_marker=$RUNTIME/goal004-owned
tmp=
pod_ip=
namespace_created=false
topology_created=false
veth_created=false
host_route_added=false
remote_route_added=false
route_marker_created=false
vpp_route_added=false
agent_pid=
proxy_pid=
agent_kubeconfig=
local_pid=

ssh_options=(-o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts"
  -o PreferredAuthentications=password -o PubkeyAuthentication=no)
ssh_env=(DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass")
remote_ssh() { env "${ssh_env[@]}" setsid -w ssh "${ssh_options[@]}" "$remote_user@$remote_host" "$@"; }
remote_scp() { env "${ssh_env[@]}" setsid -w scp "${ssh_options[@]}" "$@"; }
kube() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    kubectl --kubeconfig="$tmp/kubeconfig" "$@"
}
start_agent() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    "$tmp/agent" -kubeconfig "$agent_kubeconfig" -retry 1s -metrics-listen 127.0.0.1:18085 > "$tmp/agent.log" 2>&1 &
  agent_pid=$!
}
die_pod() { printf 'Goal 004 Pod Service: %s\n' "$*" >&2; exit 1; }
wait_for() {
  local label=$1 command=$2
  for attempt in {1..80}; do
    if eval "$command"; then return 0; fi
    sleep 0.25
  done
  die_pod "$label 未在 20 秒内就绪"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$namespace_created" == true ]]; then
    kube delete namespace "$namespace" --ignore-not-found --wait=true --timeout=120s || status=1
    remaining_namespace=$(kube get namespace "$namespace" --ignore-not-found -o name) || status=1
    [[ -z "$remaining_namespace" ]] || status=1
  fi
  if [[ -n "$agent_pid" ]]; then kill "$agent_pid" 2>/dev/null || true; wait "$agent_pid" 2>/dev/null || true; fi
  if [[ -n "$proxy_pid" ]]; then kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; fi
  if [[ -n "$local_pid" ]]; then kill "$local_pid" 2>/dev/null || true; wait "$local_pid" 2>/dev/null || true; fi
  if [[ "$route_marker_created" == true ]]; then
    printf '[]\n' > "$tmp/empty.json"
    go run ./cmd/goal003-reconcile -desired "$tmp/empty.json" || status=1
    go run ./cmd/goal004-purge -pod-backend "$pod_ip" || status=1
  fi
  if [[ "$vpp_route_added" == true ]]; then
    go run ./cmd/goal004-route -prefix "$pod_ip/32" del || status=1
  fi
  if [[ "$route_marker_created" == true ]]; then
    [[ -f "$route_marker" ]] && unlink "$route_marker"
  fi
  if [[ "$remote_route_added" == true ]]; then
    remote_ssh 'ip route del 10.10.1.2/32 dev tun3' || status=1
  fi
  if [[ "$host_route_added" == true ]]; then
    ip route del 10.10.1.2/32 via "$ns_ip" dev "$host_if" || status=1
  fi
  if [[ "$veth_created" == true ]]; then ip link del "$host_if" || status=1; fi
  if [[ "$topology_created" == true ]]; then scripts/goal001/cleanup-topology.sh || status=1; fi
  if [[ -n "$tmp" ]]; then
    [[ $(ip -4 route show default) == "$before_route" ]] || { printf '本机默认路由变化\n' >&2; status=1; }
    [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '本机管理接口变化\n' >&2; status=1; }
    [[ $(ip netns list) == "$before_namespaces" ]] || { printf '本机 namespace 未清理\n' >&2; status=1; }
    [[ -z $(ip route show exact 10.10.1.2/32) && ! -e "$route_marker" ]] || status=1
    ! ip link show "$host_if" >/dev/null 2>&1 || status=1
    if [[ "$topology_created" == true ]]; then
      inspect=$(go run ./cmd/goal002-inspect) || status=1
      grep -Fq 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0' <<<"$inspect" || status=1
    fi
    if [[ -n "$before_remote_route" ]]; then
      [[ $(remote_ssh 'ip -4 route show default') == "$before_remote_route" ]] || status=1
      [[ $(remote_ssh "ip -br addr show $remote_management_if") == "$before_remote_management" ]] || status=1
      remote_ssh 'test -z "$(ip route show exact 10.10.1.2/32)"' || status=1
    fi
    for file in "$tmp"/*; do [[ ! -f "$file" ]] || unlink "$file"; done
    rmdir "$tmp" || status=1
  fi
  printf 'Goal 004 physical Pod Service cleanup status=%s\n' "$status"
  exit "$status"
}

require_root
require_vpp
[[ -x "$askpass" && -r "$known_hosts" ]] || die_pod 'SSH helper/known_hosts 不可用'
systemctl is-active --quiet goal004-worker-tcp-link || die_pod 'TCP 节点链路未运行'
[[ $(ip route show exact "${GOAL004_REMOTE_NODE_IP:?}/32") == *' dev tun3 '* ]] || die_pod '远端 Node IP 未经 tun3'
[[ -z $(ip netns list) && ! -e "$MARKER" && ! -e "$route_marker" ]] || die_pod '已有实验 namespace/marker'
[[ -z $(ip route show exact 10.10.1.2/32) && -z $(ip route show exact 10.200.4.0/30) ]] || die_pod '本机实验 route 冲突'
! ip link show "$host_if" >/dev/null 2>&1 || die_pod '本机实验 veth 冲突'
remote_ssh 'test -z "$(ip route show exact 10.10.1.2/32)"' || die_pod '远端 client /32 route 冲突'
inspect=$(go run ./cmd/goal002-inspect) || die_pod 'VPP Binary API 不可用'
grep -Fq 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0' <<<"$inspect" || die_pod 'VPP 不是干净基线'

before_route=$(ip -4 route show default)
management_if=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$before_route")
[[ -n "$management_if" ]] || die_pod '无法识别管理接口'
before_management=$(ip -br addr show "$management_if")
before_namespaces=$(ip netns list)
before_remote_route=$(remote_ssh 'ip -4 route show default')
remote_management_if=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$before_remote_route")
[[ -n "$remote_management_if" ]] || die_pod '无法识别远端管理接口'
before_remote_management=$(remote_ssh "ip -br addr show $remote_management_if")
tmp=$(mktemp -d /tmp/goal004-pod-service.XXXXXX)
chmod 700 "$tmp"
trap cleanup EXIT
{ date -u; ip netns list; ip -br link; ip -br addr; ip -4 route; sysctl net.ipv4.ip_forward; vppctl -s "$CLI_SOCKET" show interface; } > "$tmp/host-before.txt"
remote_ssh "{ date -u; ip netns list; ip -br link; ip -br addr; ip -4 route; sysctl net.ipv4.ip_forward; }" > "$tmp/remote-before.txt"

remote_scp "$remote_user@$remote_host:/etc/kubernetes/admin.conf" "$tmp/kubeconfig"
chmod 600 "$tmp/kubeconfig"
agent_kubeconfig=$tmp/kubeconfig
if [[ "${GOAL006_WATCH_DROP:-false}" == true ]]; then
  python3 -u scripts/goal006/api-watch-proxy.py \
    --source-kubeconfig "$tmp/kubeconfig" --agent-kubeconfig "$tmp/agent-kubeconfig" \
    > "$tmp/proxy.log" 2>&1 &
  proxy_pid=$!
  wait_for 'loopback API proxy' "grep -Fq 'READY: loopback API proxy' '$tmp/proxy.log'"
  agent_kubeconfig=$tmp/agent-kubeconfig
fi
kube get nodes -o wide
[[ $(kube get node "$remote_node" -o jsonpath='{.spec.podCIDR}') == 10.244.0.0/24 ]] || die_pod '远端 Node PodCIDR 与路由安全范围不符'
! kube get namespace "$namespace" >/dev/null 2>&1 || die_pod '测试 namespace 已存在，拒绝接管'
namespace_created=true
cat > "$tmp/backend.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
---
apiVersion: v1
kind: Pod
metadata:
  name: us-backend
  namespace: $namespace
spec:
  nodeName: $remote_node
  restartPolicy: Never
  containers:
    - name: server
      image: busybox:1.36
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "mkdir -p /www; printf '%s\\n' \"\$POD_IP\" > /www/index.html; exec httpd -f -p 18080 -h /www"]
      env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
      ports:
        - containerPort: 18080
YAML
kube apply -f "$tmp/backend.yaml"
kube -n "$namespace" wait --for=condition=Ready pod/us-backend --timeout=120s
pod_ip=$(kube -n "$namespace" get pod us-backend -o jsonpath='{.status.podIP}')
[[ "$pod_ip" == 10.244.0.* ]] || die_pod "Pod IP $pod_ip 不在预期远端 PodCIDR"
[[ $(kube -n "$namespace" get pod us-backend -o jsonpath='{.spec.nodeName}') == "$remote_node" ]] || die_pod 'Pod 未运行在远端节点'
[[ $(curl --noproxy '*' -fsS --max-time 5 "http://$pod_ip:18080/") == "$pod_ip" ]] || die_pod '本机到远端 Pod TCP 直连失败'
printf '远端 Pod %s 位于 %s；本机直连 TCP 成功\n' "$pod_ip" "$remote_node"

topology_created=true
scripts/goal001/setup-topology.sh
scripts/goal001/configure-forwarding.sh
ip link add "$host_if" type veth peer name "$ns_if"
veth_created=true
ip link set "$ns_if" netns "$SERVER_NS"
ip addr add "$host_ip/30" dev "$host_if"
ip link set "$host_if" up
ip -n "$SERVER_NS" addr add "$ns_ip/30" dev "$ns_if"
ip -n "$SERVER_NS" link set "$ns_if" up
ip netns exec "$SERVER_NS" sysctl -w net.ipv4.ip_forward=1
ip -n "$SERVER_NS" route add "$pod_ip/32" via "$host_ip" dev "$ns_if"
ip route add 10.10.1.2/32 via "$ns_ip" dev "$host_if"
host_route_added=true
remote_ssh 'ip route add 10.10.1.2/32 dev tun3 src 10.253.0.1'
remote_route_added=true
install -m 0600 /dev/null "$route_marker"
route_marker_created=true
go run ./cmd/goal004-route -prefix "$pod_ip/32" add
vpp_route_added=true
go run ./cmd/goal004-route -prefix "$pod_ip/32" inspect
ip netns exec "$CLIENT_NS" ping -n -c 3 -W 3 "$pod_ip"

ip netns exec "$SERVER_NS" python3 -u scripts/goal004/traffic.py server --bind 10.10.2.2 > "$tmp/local-server.log" 2>&1 &
local_pid=$!
wait_for '本地 backend' "grep -Fq 'backend server ready' '$tmp/local-server.log'"
go build -o "$tmp/agent" ./cmd/vpp-service-agent
start_agent
wait_for 'controller 初始同步' "grep -Fq 'services=0 changed=0' '$tmp/agent.log'"
cat > "$tmp/service.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: goal004-pod-vip
  namespace: $namespace
  annotations:
    vpp-gateway.example/test-vip: "198.19.0.20"
spec:
  type: ClusterIP
  ports:
    - name: tcp
      protocol: TCP
      port: 18080
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: goal004-pod-vip-manual
  namespace: $namespace
  labels:
    kubernetes.io/service-name: goal004-pod-vip
    endpointslice.kubernetes.io/managed-by: goal004-pod-service-test
addressType: IPv4
ports:
  - name: tcp
    protocol: TCP
    port: 18080
endpoints:
  - addresses: ["10.10.2.2"]
    nodeName: $local_node
    conditions: {ready: true}
  - addresses: ["$pod_ip"]
    nodeName: $remote_node
    conditions: {ready: true}
YAML
kube apply -f "$tmp/service.yaml"
wait_for '双 backend CNAT translation' "vppctl -s '$CLI_SOCKET' show cnat translation | grep -Fq '$pod_ip;18080'"
vppctl -s "$CLI_SOCKET" clear trace
vppctl -s "$CLI_SOCKET" clear errors
vppctl -s "$CLI_SOCKET" trace add virtio-input 128
ip netns exec "$CLIENT_NS" python3 scripts/goal004/pod_service_traffic.py --pod-ip "$pod_ip" --flows 40 --base-port 52000 --expect both
if [[ "${GOAL006_WATCH_DROP:-false}" == true ]]; then
  kill -USR1 "$proxy_pid"
  wait_for 'API watch proxy 已断开' "grep -Fq 'PAUSED: existing API connections closed' '$tmp/proxy.log'"
  kube -n "$namespace" patch endpointslice goal004-pod-vip-manual --type=json \
    -p='[{"op":"replace","path":"/endpoints/1/conditions/ready","value":false}]'
  sleep 1
  vppctl -s "$CLI_SOCKET" show cnat translation | grep -Fq "$pod_ip;18080" || die_pod 'API 断开期间 CNAT translation 提前变化'
  kill -USR2 "$proxy_pid"
  wait_for 'API watch proxy 已恢复' "grep -Fq 'RESUMED: new API connections accepted' '$tmp/proxy.log'"
  wait_for 'watch 重连后远端 backend 删除' "! vppctl -s '$CLI_SOCKET' show cnat translation | grep -Fq '$pod_ip;18080'"
  kill -0 "$agent_pid" || die_pod 'watch 断连后 controller 退出'
  ip netns exec "$CLIENT_NS" python3 scripts/goal004/pod_service_traffic.py \
    --pod-ip "$pod_ip" --flows 10 --base-port 56000 --expect local
  kube -n "$namespace" patch endpointslice goal004-pod-vip-manual --type=json \
    -p='[{"op":"replace","path":"/endpoints/1/conditions/ready","value":true}]'
  wait_for 'watch 恢复后远端 backend 返回' "vppctl -s '$CLI_SOCKET' show cnat translation | grep -Fq '$pod_ip;18080'"
  ip netns exec "$CLIENT_NS" python3 scripts/goal004/pod_service_traffic.py \
    --pod-ip "$pod_ip" --flows 20 --base-port 57000 --expect both
  grep -E 'READY:|PAUSED:|RESUMED:|API connection established' "$tmp/proxy.log" | tail -n 12
  printf 'Goal006 真实 API watch 断连/恢复与 CNAT 重新收敛通过\n'
fi
if [[ "${GOAL006_CONTROLLER_RESTART:-false}" == true ]]; then
  kill "$agent_pid"
  wait "$agent_pid" 2>/dev/null || true
  agent_pid=
  mv "$tmp/agent.log" "$tmp/agent-before-restart.log"
  start_agent
  wait_for 'controller cache 重新同步' "grep -Fq 'services=1 changed=0' '$tmp/agent.log'"
  go run ./cmd/goal002-inspect | grep -F 'CNAT translations=1'
  ip netns exec "$CLIENT_NS" python3 scripts/goal004/pod_service_traffic.py \
    --pod-ip "$pod_ip" --flows 20 --base-port 55000 --expect both
  printf 'Goal006 controller/API 重新连接后新 TCP flow 通过\n'
fi
vppctl -s "$CLI_SOCKET" show trace > "$tmp/trace.txt"
grep -Fq "$pod_ip;18080" "$tmp/trace.txt" || die_pod 'trace 未捕获远端 Pod backend'
grep -Fq 'created session' "$tmp/trace.txt" || die_pod 'trace 未捕获 CNAT session 创建'
grep -Fq 'found session' "$tmp/trace.txt" || die_pod 'trace 未捕获 CNAT 反向 session'
grep -Fq 'tap102-tx' "$tmp/trace.txt" || die_pod 'trace 未捕获 VPP 输出'
grep -E 'virtio-input|ip4-cnat-tx|ip4-rewrite|tap102-output|tap102-tx|created session|found session' "$tmp/trace.txt" | awk 'NR <= 35'
go run ./cmd/goal002-inspect
vppctl -s "$CLI_SOCKET" show ip fib "$pod_ip/32"
vppctl -s "$CLI_SOCKET" show ip neighbors

kube -n "$namespace" patch endpointslice goal004-pod-vip-manual --type=json \
  -p='[{"op":"replace","path":"/endpoints/1/conditions/ready","value":false}]'
wait_for '远端 Pod backend 删除' "! vppctl -s '$CLI_SOCKET' show cnat translation | grep -Fq '$pod_ip;18080'"
ip netns exec "$CLIENT_NS" python3 scripts/goal004/pod_service_traffic.py --pod-ip "$pod_ip" --flows 10 --base-port 53000 --expect local
kube -n "$namespace" patch endpointslice goal004-pod-vip-manual --type=json \
  -p='[{"op":"replace","path":"/endpoints/1/conditions/ready","value":true}]'
wait_for '远端 Pod backend 恢复' "vppctl -s '$CLI_SOCKET' show cnat translation | grep -Fq '$pod_ip;18080'"
ip netns exec "$CLIENT_NS" python3 scripts/goal004/pod_service_traffic.py --pod-ip "$pod_ip" --flows 40 --base-port 54000 --expect both
vppctl -s "$CLI_SOCKET" show threads
vppctl -s "$CLI_SOCKET" show runtime | grep -E 'virtio-input|ip4-cnat-tx|ip4-rewrite'
vppctl -s "$CLI_SOCKET" show errors
printf 'Goal 004 physical Pod Service TCP E2E 通过\n'
