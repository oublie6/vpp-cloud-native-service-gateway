#!/usr/bin/env bash
# Goal005 插件验证；失败注入仅操作独立 VPP 和本 Goal 临时 plugin 文件。
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/scripts/goal001/topology-common.sh"
plugin=/usr/lib/x86_64-linux-gnu/vpp_plugins/goal005_observe_plugin.so
pending_plugin=/usr/lib/x86_64-linux-gnu/vpp_plugins/.goal005_observe_plugin.$$.tmp
build=/tmp/goal005-build
fail_at=${GOAL005_FAIL_AT:-}
case "$fail_at" in
  ''|build|install|start|api-enable|traffic) ;;
  *) die "未知 Goal005 失败注入阶段：$fail_at" ;;
esac

require_root
require_vpp
[[ ! -e "$plugin" && ! -e "$pending_plugin" ]] || die "已有 Goal005 plugin 文件，拒绝覆盖：$plugin"
[[ ! -e "$MARKER" ]] || die 'Goal001 拓扑已存在，拒绝接管'
before_pid=$(<"$RUNTIME/vpp.pid")
before_route=$(ip -4 route show default)
management_if=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$before_route")
[[ -n "$management_if" ]] || die '无法确定管理接口'
before_management=$(ip -o -4 addr show dev "$management_if")
before_namespaces=$(ip netns list)
original_stopped=false
plugin_installed=false
test_vpp_started=false
topology_created=false

cleanup() {
  local status=$? check=0
  trap - EXIT
  if [[ "$topology_created" == true && -f "$MARKER" ]] && vpp_cli 'show version' >/dev/null 2>&1; then
    "$repo/scripts/goal001/cleanup-topology.sh" || status=1
  fi
  if [[ "$original_stopped" == true ]]; then
    # start-vpp 即使报告失败也可能留下子进程；只停止带本项目 config 的实例。
    if [[ -f "$RUNTIME/vpp.pid" ]]; then
      "$repo/scripts/goal001/stop-vpp.sh" || status=1
    fi
  fi
  if [[ "$plugin_installed" == true ]]; then
    [[ -e "$plugin" ]] && unlink "$plugin" || true
  fi
  [[ ! -e "$pending_plugin" ]] || unlink "$pending_plugin" || status=1
  if [[ "$original_stopped" == true ]]; then
    "$repo/scripts/goal001/start-vpp.sh" || status=1
  fi
  if [[ -f "$MARKER" ]]; then
    # 目标 VPP 异常退出时，恢复原实例后按 ownership marker 清理 namespace。
    "$repo/scripts/goal001/cleanup-topology.sh" || status=1
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf '默认路由变化\n' >&2; check=1; }
  [[ $(ip -o -4 addr show dev "$management_if") == "$before_management" ]] || { printf '管理接口变化\n' >&2; check=1; }
  [[ $(ip netns list) == "$before_namespaces" ]] || { printf 'namespace 未恢复\n' >&2; check=1; }
  [[ ! -e "$plugin" && ! -e "$pending_plugin" && ! -e "$MARKER" ]] || check=1
  if [[ "$original_stopped" == false ]]; then
    [[ $(<"$RUNTIME/vpp.pid") == "$before_pid" ]] || check=1
  fi
  if ! vpp_cli 'show version' >/dev/null 2>&1 || [[ ! -S "$RUNTIME/api.sock" ]]; then check=1; fi
  if vpp_cli 'show plugins' | grep -Fq 'goal005_observe_plugin.so'; then check=1; fi
  if vpp_cli 'show interface' | grep -Eq '^[[:space:]]*tap10[12][[:space:]]'; then check=1; fi
  (( check == 0 )) || status=1
  printf 'Goal005 cleanup status=%s states: original_stopped=%s plugin_installed=%s test_vpp_started=%s topology_created=%s\n' \
    "$status" "$original_stopped" "$plugin_installed" "$test_vpp_started" "$topology_created"
  exit "$status"
}
trap cleanup EXIT

printf 'Goal005 before: pid=%s route=%s namespaces=%s\n' "$before_pid" "$before_route" "$before_namespaces"
cmake -S "$repo/plugins/goal005-observe" -B "$build" -G Ninja >/dev/null
[[ "$fail_at" != build ]] || die '注入：build 失败，原 VPP 尚未停止'
cmake --build "$build"

"$repo/scripts/goal001/stop-vpp.sh"
original_stopped=true
[[ "$fail_at" != install ]] || die '注入：plugin install 失败'
# 先写唯一临时文件，再用 hard link 原子创建目标；绝不覆盖预存同名插件。
install -m 0644 "$build/vpp_plugins/goal005_observe_plugin.so" "$pending_plugin"
ln "$pending_plugin" "$plugin" || die 'plugin 目标路径被占用，拒绝覆盖'
plugin_installed=true
unlink "$pending_plugin"
[[ "$fail_at" != start ]] || die '注入：start-vpp 失败'
"$repo/scripts/goal001/start-vpp.sh"
test_vpp_started=true
vpp_cli 'show plugins' | grep -F 'goal005_observe_plugin.so'
topology_created=true
"$repo/scripts/goal001/setup-topology.sh"
"$repo/scripts/goal001/configure-forwarding.sh"

if go run "$repo/cmd/goal005-observe" enable does-not-exist >/dev/null 2>&1; then
  die '不存在的 interface 意外成功'
fi
if [[ "$fail_at" == api-enable ]]; then
  # 真正发送错误 interface 的 GoVPP API 请求并确认失败，然后测试回滚。
  go run "$repo/cmd/goal005-observe" enable does-not-exist >/dev/null 2>&1 || die '注入：API enable 失败'
fi
go run "$repo/cmd/goal005-observe" enable tap101
vpp_cli 'show interface features tap101' | grep -F 'goal005-observe'
[[ "$fail_at" != traffic ]] || die '注入：packet E2E 失败'
vpp_cli 'clear trace' >/dev/null
vpp_cli 'clear errors' >/dev/null
vpp_cli 'trace add virtio-input 24' >/dev/null
"$repo/scripts/goal001/test-forwarding.sh"
trace=$(vpp_cli 'show trace')
printf '%s\n' "$trace" > /tmp/goal005-last-trace.txt
[[ "$trace" == *'goal005-observe rx 1 10.10.1.2 -> 10.10.2.2'* ]] || die 'trace 中无 Goal005 node'
[[ "$trace" == *'ip4-rewrite'* && "$trace" == *'tap102-output'* ]] || die 'trace 中无成功输出路径'
printf '%s\n' "$trace" | grep -E 'virtio-input|ethernet-input|ip4-input|goal005-observe|ip4-lookup|ip4-rewrite|tap102-output' | head -45
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
