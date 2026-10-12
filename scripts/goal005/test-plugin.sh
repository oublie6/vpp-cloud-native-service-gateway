#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/scripts/goal001/topology-common.sh"
plugin=/usr/lib/x86_64-linux-gnu/vpp_plugins/goal005_observe_plugin.so
build=/tmp/goal005-build
owned=0
default_before=$(ip -4 route show default)
management_before=$(ip -o -4 addr show dev eth0)
namespaces_before=$(ip netns list)

cleanup() {
  local status=$?
  local checks_ok=0
  trap - EXIT
  if [[ -f "$MARKER" ]]; then "$repo/scripts/goal001/cleanup-topology.sh" || status=1; fi
  if (( owned )); then
    "$repo/scripts/goal001/stop-vpp.sh" || status=1
    if [[ -f "$plugin" ]]; then unlink "$plugin" || status=1; fi
    "$repo/scripts/goal001/start-vpp.sh" || status=1
  fi
  printf 'cleanup: route=%s\n' "$(ip -4 route show default)"
  printf 'cleanup: namespaces=%s\n' "$(ip netns list | tr '\n' ' ')"
  [[ "$(ip -4 route show default)" == "$default_before" ]] || checks_ok=1
  [[ "$(ip -o -4 addr show dev eth0)" == "$management_before" ]] || checks_ok=1
  [[ "$(ip netns list)" == "$namespaces_before" ]] || checks_ok=1
  [[ ! -e "$plugin" ]] || checks_ok=1
  [[ ! -e "$MARKER" ]] || checks_ok=1
  if vpp_cli 'show plugins' | grep -Fq 'goal005_observe_plugin.so'; then checks_ok=1; fi
  printf 'cleanup: host route / eth0 IPv4 / namespace / plugin checks %s\n' "$([[ "$checks_ok" == 0 ]] && printf passed || printf failed)"
  (( checks_ok == 0 )) || status=1
  exit "$status"
}

require_root
require_vpp
[[ ! -e "$plugin" ]] || die "已有插件文件，拒绝覆盖：$plugin"
[[ ! -e "$MARKER" ]] || die 'Goal 001 拓扑已存在，请先清理'
trap cleanup EXIT

printf 'before: route=%s\n' "$(ip -4 route show default)"
printf 'before: namespaces=%s\n' "$(ip netns list | tr '\n' ' ')"
printf 'before: VPP interfaces\n'
vpp_cli 'show interface'
cmake -S "$repo/plugins/goal005-observe" -B "$build" -G Ninja >/dev/null
cmake --build "$build"
"$repo/scripts/goal001/stop-vpp.sh"
install -m 0644 "$build/vpp_plugins/goal005_observe_plugin.so" "$plugin"
owned=1
"$repo/scripts/goal001/start-vpp.sh"
vpp_cli 'show plugins' | grep -F 'goal005_observe_plugin.so'
"$repo/scripts/goal001/setup-topology.sh"
"$repo/scripts/goal001/configure-forwarding.sh"

if go run "$repo/cmd/goal005-observe" enable does-not-exist >/dev/null 2>&1; then
  die '不存在的 interface 意外成功'
fi
go run "$repo/cmd/goal005-observe" enable tap101
vpp_cli 'show interface features tap101' | grep -F 'goal005-observe'
vpp_cli 'clear trace' >/dev/null
vpp_cli 'clear errors' >/dev/null
vpp_cli 'trace add virtio-input 24' >/dev/null
"$repo/scripts/goal001/test-forwarding.sh"
printf '=== feature trace ===\n'
trace=$(vpp_cli 'show trace')
printf '%s\n' "$trace" > /tmp/goal005-last-trace.txt
[[ "$trace" == *'goal005-observe rx 1 10.10.1.2 -> 10.10.2.2'* ]] || die 'trace 中无 Goal 005 node'
[[ "$trace" == *'ip4-rewrite'* && "$trace" == *'tap102-output'* ]] || die 'trace 中无成功输出路径'
printf '%s\n' "$trace" | grep -E 'virtio-input|ethernet-input|ip4-input|goal005-observe|ip4-lookup|ip4-rewrite|tap102-output' | head -45
printf '=== counters ===\n'
vpp_cli 'show errors'
vpp_cli 'show runtime' | grep -F 'goal005-observe'
vpp_cli 'show threads'

go run "$repo/cmd/goal005-observe" disable tap101
vpp_cli 'show interface features tap101' | sed -n '/ip4-unicast:/,+2p'
before_count=$(vpp_cli 'show errors' | awk '$2 == "goal005-observe" {print $1}')
ip netns exec "$CLIENT_NS" ping -n -c 2 -W 2 "${SERVER_ADDR%/*}"
after_count=$(vpp_cli 'show errors' | awk '$2 == "goal005-observe" {print $1}')
[[ "$before_count" == "$after_count" ]] || die "disable 后计数仍变化：$before_count -> $after_count"
printf 'disable 后观察计数保持 %s\n' "$after_count"
