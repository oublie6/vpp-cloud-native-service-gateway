#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/topology-common.sh"
require_root
require_vpp

if [[ -e "$MARKER" ]]; then
  [[ -f "$MARKER" ]] || die "ownership marker 异常：$MARKER"
  ip netns exec "$CLIENT_NS" ip link show "$CLIENT_HOST_IF" >/dev/null 2>&1 || die '已有拓扑不完整，请先运行 cleanup-topology.sh'
  ip netns exec "$SERVER_NS" ip link show "$SERVER_HOST_IF" >/dev/null 2>&1 || die '已有拓扑不完整，请先运行 cleanup-topology.sh'
  vpp_cli 'show interface' | grep -Fq "$CLIENT_VPP_IF" || die '已有拓扑缺少 client VPP TAP'
  vpp_cli 'show interface' | grep -Fq "$SERVER_VPP_IF" || die '已有拓扑缺少 server VPP TAP'
  printf 'Goal 001 拓扑已存在\n'
  exit 0
fi
for ns in "$CLIENT_NS" "$SERVER_NS"; do
  ip netns list | grep -Eq "^${ns}( |$)" && die "namespace 已存在但非本脚本所有：$ns"
done
for id in "$CLIENT_TAP_ID" "$SERVER_TAP_ID"; do
  vpp_cli 'show interface' | grep -Eq "^[[:space:]]*tap${id}[[:space:]]" && die "VPP tap${id} 已存在但非本脚本所有"
done

# 先记录与实验相关的 host/VPP 状态；marker 只保护本脚本创建的对象。
{
  printf '%s\n' 'ip netns list'; ip netns list
  printf '%s\n' 'ip link'; ip -br link
  printf '%s\n' 'ip addr'; ip -br addr
  printf '%s\n' 'ip route'; ip -4 route
  printf '%s\n' 'VPP show interface'; vpp_cli 'show interface'
} > "$BEFORE"
printf 'goal001-tap-topology\n' > "$MARKER"
ip netns add "$CLIENT_NS" || die "创建 namespace $CLIENT_NS 失败"
ip netns add "$SERVER_NS" || die "创建 namespace $SERVER_NS 失败"
ip -n "$CLIENT_NS" link set lo up
ip -n "$SERVER_NS" link set lo up
vpp_cli "create tap id $CLIENT_TAP_ID host-ns $CLIENT_NS host-if-name $CLIENT_HOST_IF" >/dev/null
vpp_cli "create tap id $SERVER_TAP_ID host-ns $SERVER_NS host-if-name $SERVER_HOST_IF" >/dev/null
ip -n "$CLIENT_NS" addr add "$CLIENT_ADDR" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" addr add "$SERVER_ADDR" dev "$SERVER_HOST_IF"
ip -n "$CLIENT_NS" link set "$CLIENT_HOST_IF" up
ip -n "$SERVER_NS" link set "$SERVER_HOST_IF" up
printf 'Goal 001 TAP 拓扑已创建：%s/%s -> VPP -> %s/%s\n' "$CLIENT_NS" "$CLIENT_HOST_IF" "$SERVER_NS" "$SERVER_HOST_IF"
