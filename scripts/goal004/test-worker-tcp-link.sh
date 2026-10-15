#!/usr/bin/env bash
# 临时 SSH/TCP TUN：验证现有 Kubernetes 节点地址与私网 API 可经 TCP 抵达。
set -Eeuo pipefail

(( EUID == 0 )) || { printf '需要 root\n' >&2; exit 1; }
remote_host=${GOAL004_REMOTE_HOST:?需要 GOAL004_REMOTE_HOST}
askpass=${GOAL004_SSH_ASKPASS:?需要 GOAL004_SSH_ASKPASS}
known_hosts=${GOAL004_KNOWN_HOSTS:?需要 GOAL004_KNOWN_HOSTS}
local_node_ip=${GOAL004_LOCAL_NODE_IP:?需要 GOAL004_LOCAL_NODE_IP}
remote_node_ip=${GOAL004_REMOTE_NODE_IP:?需要 GOAL004_REMOTE_NODE_IP}
api_ip=${GOAL004_API_IP:?需要 GOAL004_API_IP}
remote_user=${GOAL004_REMOTE_USER:-root}
remote="$remote_user@$remote_host"
remote_dir=/run/goal004-worker-tcp
tmp=
sshd_job=
sshd_started=false
outer_started=false
inner_started=false
local_route_added=false
api_route_changed=false
remote_route_added=false
local_addr_added=false
remote_addr_added=false
remote_dir_created=false
ssh_options=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts"
  -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8)
ssh_env=(DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass")

die() { printf 'Goal 004 TCP link: %s\n' "$*" >&2; exit 1; }
remote_ssh() { env "${ssh_env[@]}" setsid -w ssh "${ssh_options[@]}" "$remote" "$@"; }
wait_for() {
  local label=$1 command=$2
  for attempt in {1..60}; do
    if eval "$command"; then return 0; fi
    sleep 0.2
  done
  die "$label 未就绪"
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$api_route_changed" == true ]]; then
    read -r -a old_api_parts <<<"$before_api_route"
    ip route replace "${old_api_parts[@]}" || status=1
  fi
  if [[ "$local_route_added" == true ]]; then
    ip route del "$remote_node_ip/32" dev tun3 || status=1
  fi
  if [[ "$remote_route_added" == true ]]; then
    remote_ssh "ip route del $local_node_ip/32 dev tun3" || status=1
  fi
  if [[ "$local_addr_added" == true ]]; then
    ip addr del 10.254.0.2/30 dev tun3 || status=1
  fi
  if [[ "$remote_addr_added" == true ]]; then
    remote_ssh 'ip addr del 10.254.0.1/30 dev tun3' || status=1
  fi
  if [[ "$inner_started" == true ]]; then
    ssh -S "$tmp/inner.ctl" -O exit -p 2222 "$remote_user@127.0.0.1" >/dev/null 2>&1 || status=1
  fi
  if [[ "$outer_started" == true ]]; then
    ssh -S "$tmp/outer.ctl" -O exit "$remote" >/dev/null 2>&1 || status=1
  fi
  if [[ "$sshd_started" == true ]]; then
    remote_ssh "if test -f $remote_dir/sshd.pid; then pid=\$(cat $remote_dir/sshd.pid); if tr '\\0' ' ' < /proc/\$pid/cmdline | grep -Fq 'sshd -D -e -p 2222'; then kill \"\$pid\"; fi; fi" || status=1
    kill "$sshd_job" 2>/dev/null || true
    wait "$sshd_job" 2>/dev/null || true
  fi
  if [[ "$remote_dir_created" == true ]]; then
    remote_ssh "test ! -f $remote_dir/sshd.pid || unlink $remote_dir/sshd.pid; rmdir $remote_dir" || status=1
  fi
  if [[ -n "$tmp" ]]; then
    [[ $(ip -4 route show default) == "$before_route" ]] || { printf '本机默认路由变化\n' >&2; status=1; }
    [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '本机管理接口变化\n' >&2; status=1; }
    [[ $(ip route show exact "$api_ip/32") == "$before_api_route" ]] || { printf '本机 API 路由未恢复\n' >&2; status=1; }
    [[ $(remote_ssh 'ip -4 route show default') == "$before_remote_route" ]] || { printf '远端默认路由变化\n' >&2; status=1; }
    [[ $(remote_ssh "ip -br addr show $remote_management_if") == "$before_remote_management" ]] || { printf '远端管理接口变化\n' >&2; status=1; }
    for file in "$tmp"/*; do
      [[ ! -f "$file" && ! -S "$file" ]] || unlink "$file"
    done
    rmdir "$tmp" || status=1
  fi
  printf 'Goal 004 TCP link cleanup status=%s\n' "$status"
  exit "$status"
}

[[ -x "$askpass" && -r "$known_hosts" ]] || die 'SSH askpass/known_hosts 不可用'
[[ -c /dev/net/tun ]] || die '本机缺少 /dev/net/tun'
[[ ! -e /run/goal004-worker-tcp ]] || die '本机实验目录冲突'
! ip link show dev tun3 >/dev/null 2>&1 || die '本机 tun3 已存在'
! ss -ltn '( sport = :2222 )' | grep -q LISTEN || die '本机端口 2222 已占用'
remote_ssh "test -c /dev/net/tun && test ! -e $remote_dir && ! ip link show dev tun3 >/dev/null 2>&1 && ! ss -ltn '( sport = :2222 )' | grep -q LISTEN" || die '远端实验资源冲突'
[[ -z $(ip route show exact "$remote_node_ip/32") ]] || die '本机节点 /32 路由已存在'
remote_ssh "test -z \"\$(ip route show exact $local_node_ip/32)\"" || die '远端节点 /32 路由已存在'
before_api_route=$(ip route show exact "$api_ip/32")
[[ -n "$before_api_route" ]] || die '本机 API /32 旧路由不存在，拒绝覆盖'
before_route=$(ip -4 route show default)
management_if=$(awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' <<<"$before_route")
[[ -n "$management_if" ]] || die '无法识别本机管理接口'
before_management=$(ip -br addr show "$management_if")
before_remote_route=$(remote_ssh 'ip -4 route show default')
remote_management_if=$(awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' <<<"$before_remote_route")
[[ -n "$remote_management_if" ]] || die '无法识别远端管理接口'
before_remote_management=$(remote_ssh "ip -br addr show $remote_management_if")
tmp=$(mktemp -d /run/goal004-worker-tcp.XXXXXX)
chmod 700 "$tmp"
trap cleanup EXIT
{ date -u; ip netns list; ip -br link; ip -br addr; ip route; vppctl -s /run/vpp-goal001/cli.sock show interface; } > "$tmp/before.txt"
remote_ssh "install -d -m 0700 $remote_dir"
remote_dir_created=true
remote_ssh "echo \$\$ > $remote_dir/sshd.pid; exec /usr/sbin/sshd -D -e -p 2222 -o ListenAddress=127.0.0.1 -o PermitTunnel=point-to-point" > "$tmp/sshd.log" 2>&1 &
sshd_job=$!
sshd_started=true
wait_for '远端临时 sshd' "remote_ssh \"ss -ltn '( sport = :2222 )' | grep -q LISTEN\""
env "${ssh_env[@]}" setsid -w ssh -fN -M -S "$tmp/outer.ctl" "${ssh_options[@]}" -o ExitOnForwardFailure=yes -L 127.0.0.1:2222:127.0.0.1:2222 "$remote"
outer_started=true
env "${ssh_env[@]}" setsid -w ssh -fN -M -S "$tmp/inner.ctl" -p 2222 -w 3:3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$tmp/tun-known-hosts" -o PreferredAuthentications=password -o PubkeyAuthentication=no "$remote_user@127.0.0.1"
inner_started=true
wait_for '双方 tun3' "ip link show dev tun3 >/dev/null 2>&1 && remote_ssh 'ip link show dev tun3 >/dev/null 2>&1'"
remote_ssh 'ip addr add 10.254.0.1/30 dev tun3; ip link set tun3 up'
remote_addr_added=true
ip addr add 10.254.0.2/30 dev tun3
local_addr_added=true
ip link set tun3 up
remote_ssh "ip route add $local_node_ip/32 dev tun3 src $remote_node_ip"
remote_route_added=true
ip route add "$remote_node_ip/32" dev tun3 src "$local_node_ip"
local_route_added=true
ip route replace "$api_ip/32" dev tun3 src "$local_node_ip"
api_route_changed=true
ping -n -c 2 -W 2 10.254.0.1
ping -n -I "$local_node_ip" -c 2 -W 2 "$remote_node_ip"
timeout 5 bash -c "cat </dev/null >/dev/tcp/$api_ip/6443"
printf 'Goal 004 TCP link: 节点地址和私网 API 可经 SSH/TCP TUN 访问\n'
