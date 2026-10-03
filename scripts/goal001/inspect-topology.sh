#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/topology-common.sh"
require_root
require_vpp
printf '%s\n' '=== namespaces ==='
ip netns list
for ns in "$CLIENT_NS" "$SERVER_NS"; do
  if ip netns list | grep -Eq "^${ns}( |$)"; then
    printf '=== %s: link/address/route ===\n' "$ns"
    ip -n "$ns" -br link
    ip -n "$ns" -br addr
    ip -n "$ns" -4 route
  fi
done
printf '%s\n' '=== VPP show interface ==='
vpp_cli 'show interface'
printf '%s\n' '=== VPP show hardware-interfaces ==='
vpp_cli 'show hardware-interfaces'
