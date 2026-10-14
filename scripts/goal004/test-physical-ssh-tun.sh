#!/usr/bin/env bash
# 在两台真实主机之间用临时 SSH TUN 验证 Goal 004；不接管现有 WireGuard/管理网络。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh

remote_host=${GOAL004_REMOTE_HOST:?设置 GOAL004_REMOTE_HOST 为已授权远端主机}
askpass=${GOAL004_SSH_ASKPASS:?设置 GOAL004_SSH_ASKPASS 为外部 SSH askpass 程序}
known_hosts=${GOAL004_KNOWN_HOSTS:?设置 GOAL004_KNOWN_HOSTS 为已核对的 host key 文件}
kubectl_bin=${GOAL004_KUBECTL:-kubectl}
remote_user=${GOAL004_REMOTE_USER:-root}
remote=$remote_user@$remote_host
remote_dir=/run/goal004-physical
route_marker=$RUNTIME/goal004-owned
remote_backend=10.10.4.2
local_backend=10.10.2.2
tun_remote=10.254.0.1
tun_local=10.254.0.2
test_namespace=vpp-goal004-physical
tmp=
agent_bin=
remote_dir_created=false
topology_created=false
route_marker_created=false
service_applied=false
inner_started=false
outer_started=false
sshd_started=false
local_server_pid=
remote_server_job=
sshd_job=
agent_pid=
before_remote_route=
before_remote_management=
remote_management_if=

ssh_options=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts"
  -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8)
ssh_env=(DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass")

die_physical() { printf 'Goal 004 physical: %s\n' "$*" >&2; exit 1; }
remote_ssh() { env "${ssh_env[@]}" setsid -w ssh "${ssh_options[@]}" "$remote" "$@"; }
remote_scp() { env "${ssh_env[@]}" setsid -w scp "${ssh_options[@]}" "$@"; }
remote_backend_count() {
  local translations
  translations=$(vppctl -s "$CLI_SOCKET" show cnat translation) || return 1
  grep -Fc "0.0.0.0;0->$remote_backend;18080" <<<"$translations" || true
}
wait_for() {
  local label=$1 command=$2
  for attempt in {1..60}; do
    if eval "$command"; then return 0; fi
    sleep 0.2
  done
  die_physical "$label 未就绪"
}
stop_pid() {
  local pid=$1
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$service_applied" == true ]]; then
    "$kubectl_bin" --kubeconfig="$tmp/kubeconfig" delete namespace "$test_namespace" \
      --ignore-not-found --wait=true --timeout=60s || status=1
  fi
  stop_pid "$agent_pid"
  if [[ "$topology_created" == true ]]; then
    printf '[]\n' > "$tmp/empty.json"
    go run ./cmd/goal003-reconcile -desired "$tmp/empty.json" || status=1
    go run ./cmd/goal004-purge || status=1
    if [[ "$route_marker_created" == true ]]; then
      go run ./cmd/goal004-route del || status=1
      [[ -e "$route_marker" ]] && unlink "$route_marker"
    fi
  fi
  stop_pid "$local_server_pid"
  if [[ "$remote_dir_created" == true ]]; then
    remote_ssh "if test -f $remote_dir/server.pid; then pid=\$(cat $remote_dir/server.pid); kill \"\$pid\" 2>/dev/null || true; fi; \
      ip route del 10.10.1.2/32 via $tun_local dev tun3 2>/dev/null || true; \
      ip addr del $remote_backend/32 dev lo 2>/dev/null || true; \
      ip addr del $tun_remote/30 dev tun3 2>/dev/null || true; \
      test ! -f $remote_dir/traffic.py || unlink $remote_dir/traffic.py; \
      test ! -f $remote_dir/server.pid || unlink $remote_dir/server.pid" || status=1
  fi
  stop_pid "$remote_server_job"
  if [[ "$topology_created" == true ]]; then
    if ip -n "$SERVER_NS" link show dev tun3 >/dev/null 2>&1; then
      ip -n "$SERVER_NS" route del "$remote_backend/32" via "$tun_remote" dev tun3 2>/dev/null || true
      ip -n "$SERVER_NS" addr del "$tun_local/30" dev tun3 2>/dev/null || true
    fi
  fi
  if [[ "$inner_started" == true ]]; then
    ssh -S "$tmp/inner.ctl" -O exit -p 2222 "$remote_user@127.0.0.1" >/dev/null 2>&1 || status=1
  fi
  if [[ "$topology_created" == true ]]; then
    scripts/goal001/cleanup-topology.sh || status=1
  fi
  if [[ "$outer_started" == true ]]; then
    ssh -S "$tmp/outer.ctl" -O exit "$remote" >/dev/null 2>&1 || status=1
  fi
  if [[ "$sshd_started" == true ]]; then
    remote_ssh "if test -f $remote_dir/sshd.pid; then pid=\$(cat $remote_dir/sshd.pid); \
      if tr '\\0' ' ' < /proc/\$pid/cmdline | grep -Fq 'sshd -D -e -p 2222'; then kill \"\$pid\"; fi; fi" || status=1
    stop_pid "$sshd_job"
  fi
  if [[ "$remote_dir_created" == true ]]; then
    remote_ssh "test ! -f $remote_dir/sshd.pid || unlink $remote_dir/sshd.pid; \
      test ! -f $remote_dir/before.txt || unlink $remote_dir/before.txt; rmdir $remote_dir" || status=1
    [[ $(remote_ssh 'ip -4 route show default') == "$before_remote_route" ]] || { printf '远端默认路由变化\n' >&2; status=1; }
    [[ $(remote_ssh "ip -br addr show $remote_management_if") == "$before_remote_management" ]] || { printf '远端管理接口变化\n' >&2; status=1; }
    remote_ssh "test ! -e $remote_dir && ! ip link show dev tun3 >/dev/null 2>&1 && \
      ! ip -4 addr show | grep -Fq '$remote_backend/32' && \
      test -z \"\$(ip -4 route show exact 10.10.1.2/32)\" && \
      ! ss -ltn '( sport = :2222 )' | grep -q LISTEN" || status=1
  fi
  if [[ -n "$tmp" ]]; then
    [[ $(ip -4 route show default) == "$before_route" ]] || { printf 'host 默认路由变化\n' >&2; status=1; }
    [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '管理接口变化\n' >&2; status=1; }
    [[ $(ip netns list) == "$before_namespaces" ]] || { printf 'namespace 列表变化\n' >&2; status=1; }
    if [[ "$topology_created" == true ]]; then
      inspect=$(go run ./cmd/goal002-inspect) || status=1
      grep -Fq 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0' <<<"$inspect" || status=1
    fi
    for file in "$tmp"/*; do
      [[ ! -f "$file" && ! -S "$file" ]] || unlink "$file"
    done
    rmdir "$tmp" || status=1
  fi
  if [[ -n "$agent_bin" && -f "$agent_bin" ]]; then unlink "$agent_bin"; fi
  printf 'Goal 004 physical cleanup status=%s\n' "$status"
  exit "$status"
}

require_root
require_vpp
command -v "$kubectl_bin" >/dev/null || die_physical "缺少 kubectl: $kubectl_bin"
[[ -x "$askpass" && -r "$known_hosts" ]] || die_physical 'SSH askpass/known_hosts 不可用'
[[ ! -e "$MARKER" && ! -e "$route_marker" ]] || die_physical '实验 marker 已存在'
[[ -z $(ip netns list) ]] || die_physical '已有 namespace，拒绝接管'
inspect=$(go run ./cmd/goal002-inspect) || die_physical '无法读取 VPP API 状态'
grep -Fq 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0' <<<"$inspect" || die_physical 'VPP 非干净基线'
[[ ! -e /run/goal004-physical ]] || die_physical '本地实验目录已存在'
! ip link show dev tun3 >/dev/null 2>&1 || die_physical 'tun3 已存在'
! ss -ltn '( sport = :2222 or sport = :16443 )' | grep -q LISTEN || die_physical 'SSH 实验端口已占用'
remote_ssh "test ! -e $remote_dir && test ! -e /sys/class/net/tun3 && \
  ! ss -ltn '( sport = :2222 )' | grep -q LISTEN && \
  ! ip -4 addr show | grep -Fq '$remote_backend/32' && \
  test -z \"\$(ip -4 route show exact 10.10.1.2/32)\"" || die_physical '远端实验资源冲突'
[[ -c /dev/net/tun ]] || die_physical '本机缺少 /dev/net/tun'
remote_ssh 'test -c /dev/net/tun' || die_physical '远端缺少 /dev/net/tun'

before_route=$(ip -4 route show default)
management_if=$(ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[[ -n "$management_if" ]] || die_physical '无法确定管理接口'
before_management=$(ip -br addr show "$management_if")
before_namespaces=$(ip netns list)
before_remote_route=$(remote_ssh 'ip -4 route show default')
remote_management_if=$(awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$before_remote_route")
[[ -n "$remote_management_if" ]] || die_physical '无法确定远端管理接口'
before_remote_management=$(remote_ssh "ip -br addr show $remote_management_if")
tmp=$(mktemp -d /run/goal004-physical.XXXXXX)
chmod 700 "$tmp"
agent_bin=$(mktemp /tmp/goal004-physical-agent.XXXXXX)
trap cleanup EXIT

{ date -u; ip netns list; ip -brief link; ip -brief -4 addr; ip -4 route; \
  sysctl net.ipv4.ip_forward; vppctl -s "$CLI_SOCKET" show interface; } > "$tmp/before.txt"
remote_dir_created=true
remote_ssh "install -d -m 0700 $remote_dir; { date -u; ip netns list; ip -brief link; \
  ip -brief -4 addr; ip -4 route; sysctl net.ipv4.ip_forward; } > $remote_dir/before.txt"

remote_ssh 'echo $$ > /run/goal004-physical/sshd.pid; exec /usr/sbin/sshd -D -e -p 2222 \
  -o ListenAddress=127.0.0.1 -o PermitTunnel=point-to-point' > "$tmp/sshd.log" 2>&1 &
sshd_job=$!
sshd_started=true
wait_for '远端临时 sshd' "remote_ssh \"ss -ltn '( sport = :2222 )' | grep -q LISTEN\""
env "${ssh_env[@]}" setsid -w ssh -fN -M -S "$tmp/outer.ctl" \
  "${ssh_options[@]}" -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:2222:127.0.0.1:2222 -L 127.0.0.1:16443:127.0.0.1:6443 "$remote"
outer_started=true
env "${ssh_env[@]}" setsid -w ssh -fN -M -S "$tmp/inner.ctl" -p 2222 -w 3:3 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$tmp/tun-known-hosts" \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no "$remote_user@127.0.0.1"
inner_started=true
wait_for '双方 tun3' "ip link show dev tun3 >/dev/null 2>&1 && remote_ssh 'ip link show dev tun3 >/dev/null 2>&1'"

remote_ssh "ip addr add $tun_remote/30 dev tun3; ip link set tun3 up; \
  ip addr add $remote_backend/32 dev lo; ip route add 10.10.1.2/32 via $tun_local dev tun3"
ip addr add "$tun_local/30" dev tun3
ip link set tun3 up
ping -n -c 2 -W 2 "$tun_remote"

topology_created=true
scripts/goal001/setup-topology.sh
scripts/goal001/configure-forwarding.sh
ip link set tun3 netns "$SERVER_NS"
ip -n "$SERVER_NS" addr add "$tun_local/30" dev tun3
ip -n "$SERVER_NS" link set tun3 up
ip netns exec "$SERVER_NS" sysctl -w net.ipv4.ip_forward=1
ip -n "$SERVER_NS" route add "$remote_backend/32" via "$tun_remote" dev tun3
ip netns exec "$SERVER_NS" ping -n -c 2 -W 2 "$tun_remote"
ip netns exec "$CLIENT_NS" ping -n -c 2 -W 2 "$local_backend"
ip netns exec "$SERVER_NS" ping -n -c 2 -W 2 "${CLIENT_ADDR%/*}"
install -m 0600 /dev/null "$route_marker"
route_marker_created=true
go run ./cmd/goal004-route add
go run ./cmd/goal004-route inspect
ip netns exec "$CLIENT_NS" ping -n -c 3 -W 2 "$remote_backend"

remote_scp scripts/goal004/traffic.py "$remote:$remote_dir/traffic.py"
remote_ssh 'echo $$ > /run/goal004-physical/server.pid; exec python3 -u /run/goal004-physical/traffic.py server --bind 10.10.4.2' > "$tmp/remote-server.log" 2>&1 &
remote_server_job=$!
ip netns exec "$SERVER_NS" python3 -u scripts/goal004/traffic.py server --bind "$local_backend" > "$tmp/local-server.log" 2>&1 &
local_server_pid=$!
wait_for '两端 backend server' "test -f '$tmp/local-server.log' && test -f '$tmp/remote-server.log' && \
  grep -Fq 'backend server ready' '$tmp/local-server.log' && grep -Fq 'backend server ready' '$tmp/remote-server.log'"

remote_scp "$remote:/etc/kubernetes/admin.conf" "$tmp/kubeconfig"
chmod 600 "$tmp/kubeconfig"
cluster_name=$("$kubectl_bin" --kubeconfig="$tmp/kubeconfig" config view --minify --output=jsonpath='{.clusters[0].name}')
api_server=$("$kubectl_bin" --kubeconfig="$tmp/kubeconfig" config view --minify --output=jsonpath='{.clusters[0].cluster.server}')
tls_server=${api_server#https://}
tls_server=${tls_server%:6443}
"$kubectl_bin" --kubeconfig="$tmp/kubeconfig" config set-cluster "$cluster_name" \
  --server=https://127.0.0.1:16443 --tls-server-name="$tls_server" >/dev/null
"$kubectl_bin" --kubeconfig="$tmp/kubeconfig" --request-timeout=5s get nodes -o wide
! "$kubectl_bin" --kubeconfig="$tmp/kubeconfig" get namespace "$test_namespace" >/dev/null 2>&1 || die_physical '实验 Kubernetes namespace 已存在'
remote_node=$(remote_ssh hostname)
local_node=$(hostname)
[[ "$remote_node" =~ ^[a-zA-Z0-9._-]+$ && "$local_node" =~ ^[a-zA-Z0-9._-]+$ ]] || die_physical 'Node 名称含非法字符'
sed -e "s/vpp-goal004/$test_namespace/g" -e "s/logical-local/$local_node/g" \
  -e "s/logical-remote/$remote_node/g" deploy/kubernetes/goal004-test.yaml > "$tmp/kubernetes.yaml"
go build -o "$agent_bin" ./cmd/vpp-service-agent
chmod 700 "$agent_bin"
"$agent_bin" -kubeconfig "$tmp/kubeconfig" -retry 1s -metrics-listen 127.0.0.1:18084 > "$tmp/agent.log" 2>&1 &
agent_pid=$!
wait_for 'controller 初始同步' "grep -Fq 'services=0 changed=0' '$tmp/agent.log'"
service_applied=true
"$kubectl_bin" --kubeconfig="$tmp/kubeconfig" apply -f "$tmp/kubernetes.yaml"
wait_for '两个 CNAT translation' 'test "$(remote_backend_count)" -eq 2'

ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 20 --base-port 41000 --require-both | tee "$tmp/udp.log"
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto tcp --flows 20 --base-port 42000 --require-both | tee "$tmp/tcp.log"
remote_index=$(awk '$1 == "udp" && $2 == "flow" && $4 == "backend" && $5 == "10.10.4.2" { print $3; exit }' "$tmp/udp.log")
[[ "$remote_index" =~ ^[0-9]+$ ]] || die_physical '未找到远端 UDP flow'
remote_port=$((41000 + remote_index))
vppctl -s "$CLI_SOCKET" clear trace
vppctl -s "$CLI_SOCKET" clear errors
vppctl -s "$CLI_SOCKET" trace add virtio-input 16
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 1 --base-port "$remote_port" --expect-backend "$remote_backend"
vppctl -s "$CLI_SOCKET" show trace | awk '/^Packet [0-9]+/ { if (packet >= 4) exit; packet++ } packet && (/^Packet [0-9]+/ || /^[0-9][0-9]:/ || /session:/ || /found session/ || /created session/) { print }'
go run ./cmd/goal002-inspect

ip -n "$SERVER_NS" link set tun3 down
if ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 1 --base-port "$remote_port" --expect-backend "$remote_backend" > "$tmp/failure.log" 2>&1; then
  die_physical '链路 down 后旧远端 flow 仍成功'
fi
grep -Fq 'timed out' "$tmp/failure.log" || die_physical '链路 down 失败原因并非 timeout'
"$kubectl_bin" --kubeconfig="$tmp/kubeconfig" -n "$test_namespace" patch endpointslice echo-two-node-manual --type=json \
  -p='[{"op":"replace","path":"/endpoints/1/conditions/ready","value":false}]'
wait_for '远端 backend 移除' 'test "$(remote_backend_count)" -eq 0'
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 10 --base-port 45000 --expect-backend "$local_backend" --quiet

ip -n "$SERVER_NS" link set tun3 up
if ! ip -n "$SERVER_NS" route show exact "$remote_backend/32" | grep -Fq "via $tun_remote dev tun3"; then
  ip -n "$SERVER_NS" route add "$remote_backend/32" via "$tun_remote" dev tun3
fi
ip netns exec "$CLIENT_NS" ping -n -c 2 -W 2 "$remote_backend"
"$kubectl_bin" --kubeconfig="$tmp/kubeconfig" -n "$test_namespace" patch endpointslice echo-two-node-manual --type=json \
  -p='[{"op":"replace","path":"/endpoints/1/conditions/ready","value":true}]'
wait_for '远端 backend 恢复' 'test "$(remote_backend_count)" -eq 2'
ip netns exec "$CLIENT_NS" python3 scripts/goal004/traffic.py client --proto udp --flows 20 --base-port 46000 --require-both --quiet
curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:18084/status
vppctl -s "$CLI_SOCKET" show threads
vppctl -s "$CLI_SOCKET" show runtime | grep -E 'virtio-input|ip4-cnat-tx|ip4-rewrite'
vppctl -s "$CLI_SOCKET" show errors
printf 'Goal 004 physical SSH TUN E2E 通过；Kubernetes worker Ready 状态以上述 get nodes 为准\n'
