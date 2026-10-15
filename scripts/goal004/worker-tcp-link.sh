#!/usr/bin/env bash
# 通过 SSH/TCP TUN 连接现有两个 Kubernetes Node IP；由 systemd 管理生命周期。
set -Eeuo pipefail

(( EUID == 0 )) || { printf '需要 root\n' >&2; exit 1; }
config=/etc/goal004-worker-tcp.env
[[ -r "$config" ]] || { printf '缺少 %s\n' "$config" >&2; exit 1; }
source "$config"
remote_host=${GOAL004_REMOTE_HOST:?}
askpass=${GOAL004_SSH_ASKPASS:?}
known_hosts=${GOAL004_KNOWN_HOSTS:?}
local_node_ip=${GOAL004_LOCAL_NODE_IP:?}
remote_node_ip=${GOAL004_REMOTE_NODE_IP:?}
api_ip=${GOAL004_API_IP:?}
remote_user=${GOAL004_REMOTE_USER:-root}
remote="$remote_user@$remote_host"
runtime=/run/goal004-worker-tcp
control_socket=$runtime/master.ctl
ssh_options=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts"
  -o PreferredAuthentications=password -o PubkeyAuthentication=no
  -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
ssh_env=(DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass")

die() { printf 'Goal 004 TCP worker link: %s\n' "$*" >&2; exit 1; }
remote_ssh() { env "${ssh_env[@]}" ssh "${ssh_options[@]}" "$remote" "$@"; }
remote_ctl() {
  ssh -S "$control_socket" -o ControlMaster=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" "$remote" "$@"
}
control_alive() {
  [[ -S "$control_socket" ]] &&
    ssh -S "$control_socket" -O check "$remote" >/dev/null 2>&1
}
wait_for_tun() {
  for attempt in {1..60}; do
    if ip link show dev tun3 >/dev/null 2>&1 && [[ -S "$control_socket" ]] &&
      remote_ctl 'ip link show dev tun3 >/dev/null 2>&1'; then return 0; fi
    kill -0 "$ssh_pid" 2>/dev/null || die 'SSH 连接提前退出'
    sleep 0.2
  done
  die 'tun3 未在预期时间就绪'
}

if [[ ${1:-run} == restore-api ]]; then
  current_api_route=$(ip route show exact "$api_ip/32")
  if [[ -z "$current_api_route" || "$current_api_route" == *' dev tun3 '* ]]; then
    ip route replace "$api_ip/32" dev wg0 scope link
  else
    read -r route_dest route_dev_key route_dev route_scope_key route_scope route_extra <<<"$current_api_route"
    [[ "$route_dest" == "$api_ip" && "$route_dev_key" == dev && "$route_dev" == wg0 &&
      "$route_scope_key" == scope && "$route_scope" == link && -z "${route_extra:-}" ]] ||
      die "API /32 路由已由其他配置管理：$current_api_route"
  fi
  exit 0
fi
[[ ${1:-run} == run ]] || die '仅支持 run 或 restore-api'
[[ -x "$askpass" && -r "$known_hosts" ]] || die 'SSH askpass/known_hosts 不可用'
[[ -d "$runtime" && -c /dev/net/tun ]] || die 'systemd RuntimeDirectory 或 /dev/net/tun 不可用'
[[ ! -e "$control_socket" ]] || die '控制 socket 已存在'
! ip link show dev tun3 >/dev/null 2>&1 || die '本机 tun3 已存在'
[[ -z $(ip route show exact "$remote_node_ip/32") ]] || die '本机节点 /32 路由已存在'
before_api_route=$(ip route show exact "$api_ip/32")
[[ -n "$before_api_route" ]] || die 'API /32 基线路由不存在'
read -r route_dest route_dev_key route_dev route_scope_key route_scope route_extra <<<"$before_api_route"
[[ "$route_dest" == "$api_ip" && "$route_dev_key" == dev && "$route_dev" == wg0 &&
  "$route_scope_key" == scope && "$route_scope" == link && -z "${route_extra:-}" ]] ||
  die 'API /32 基线不是预期 wg0 路由'
remote_ssh "sshd -T | grep -Fx 'permittunnel point-to-point' && ! ip link show dev tun3 >/dev/null 2>&1 && test -z \"\$(ip route show exact $local_node_ip/32)\"" >/dev/null || die '远端 TUN 配置或资源冲突'
before_route=$(ip -4 route show default)
management_if=$(awk '{ for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' <<<"$before_route")
[[ -n "$management_if" ]] || die '无法识别管理接口'
before_management=$(ip -br addr show "$management_if")
{ date -u; ip netns list; ip -br link; ip -br addr; ip route; if [[ -S /run/vpp-goal001/cli.sock ]]; then vppctl -s /run/vpp-goal001/cli.sock show interface; fi; } > "$runtime/before.txt"

ssh_pid=
remote_addr_added=false
remote_route_added=false
local_addr_added=false
local_route_added=false
api_route_changed=false
cleanup() {
  local status=$?
  trap - EXIT TERM INT
  if control_alive; then
    if [[ "$remote_route_added" == true ]]; then
      remote_ctl "ip route del $local_node_ip/32 dev tun3" || status=1
    fi
    if [[ "$remote_addr_added" == true ]]; then
      remote_ctl 'ip addr del 10.254.0.1/30 dev tun3' || status=1
    fi
  fi
  if [[ "$api_route_changed" == true ]]; then
    ip route replace "$api_ip/32" dev wg0 scope link || status=1
  fi
  if ip link show dev tun3 >/dev/null 2>&1; then
    if [[ "$local_route_added" == true ]]; then
      ip route del "$remote_node_ip/32" dev tun3 || status=1
    fi
    if [[ "$local_addr_added" == true ]]; then
      ip addr del 10.254.0.2/30 dev tun3 || status=1
    fi
  fi
  if [[ -n "$ssh_pid" ]]; then
    ssh -S "$control_socket" -O exit "$remote" >/dev/null 2>&1 || true
    kill "$ssh_pid" 2>/dev/null || true
    wait "$ssh_pid" 2>/dev/null || true
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf '默认路由变化\n' >&2; status=1; }
  [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '管理接口变化\n' >&2; status=1; }
  [[ $(ip route show exact "$api_ip/32") == "$before_api_route" ]] || { printf 'API /32 路由未恢复\n' >&2; status=1; }
  printf 'Goal 004 TCP worker link stopped: status=%s\n' "$status"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

env "${ssh_env[@]}" ssh -N -M -S "$control_socket" -w 3:3 "${ssh_options[@]}" -o ExitOnForwardFailure=yes "$remote" &
ssh_pid=$!
wait_for_tun
remote_ctl 'ip addr add 10.254.0.1/30 dev tun3 && ip link set tun3 up'
remote_addr_added=true
ip addr add 10.254.0.2/30 dev tun3
local_addr_added=true
ip link set tun3 up
remote_ctl "ip route add $local_node_ip/32 dev tun3 src $remote_node_ip"
remote_route_added=true
ip route add "$remote_node_ip/32" dev tun3 src "$local_node_ip"
local_route_added=true
ip route replace "$api_ip/32" dev tun3 src "$local_node_ip"
api_route_changed=true
printf 'Goal 004 TCP worker link active: %s <-> %s, API %s via tun3\n' "$local_node_ip" "$remote_node_ip" "$api_ip"
wait "$ssh_pid"
