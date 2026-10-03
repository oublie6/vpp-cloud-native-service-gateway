#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/topology-common.sh"
require_root
require_vpp
[[ -f "$MARKER" ]] || die '请先运行 setup-topology.sh'
for iface in "$CLIENT_VPP_IF" "$SERVER_VPP_IF"; do
  vpp_cli "set interface state $iface up" >/dev/null
done
if ! vpp_cli 'show interface addr' | grep -Fq "L3 $CLIENT_GW/24"; then
  vpp_cli "set interface ip address $CLIENT_VPP_IF $CLIENT_GW/24" >/dev/null
fi
if ! vpp_cli 'show interface addr' | grep -Fq "L3 $SERVER_GW/24"; then
  vpp_cli "set interface ip address $SERVER_VPP_IF $SERVER_GW/24" >/dev/null
fi
ip -n "$CLIENT_NS" route replace default via "$CLIENT_GW" dev "$CLIENT_HOST_IF"
ip -n "$SERVER_NS" route replace default via "$SERVER_GW" dev "$SERVER_HOST_IF"
printf 'Goal 001 IPv4 forwarding 已配置：%s/24 和 %s/24\n' "$CLIENT_GW" "$SERVER_GW"
