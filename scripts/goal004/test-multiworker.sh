#!/usr/bin/env bash
# 临时以两个 VPP worker 复跑 Goal 002 Service E2E，并恢复原独立实例。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh
API_SOCKET=$RUNTIME/api.sock
thread_count() { vppctl -s "$CLI_SOCKET" show threads | awk '$2 ~ /^vpp_/ { count++ } END { print count+0 }'; }

require_root
require_vpp
[[ ! -e "$MARKER" ]] || die '已有 Goal 001 拓扑，拒绝重启 VPP'
[[ $(thread_count) -eq 1 ]] || die '当前 VPP 不是单 main thread 基线'
[[ ! -e /run/vpp-goal004-multiworker ]] || die '临时配置目录已存在'

before_route=$(ip -4 route show default)
management_if=$(ip -4 route show default | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[[ -n "$management_if" ]] || die '无法确定宿主管理接口'
before_management=$(ip -br addr show "$management_if")
before_namespaces=$(ip netns list)
temporary_started=false
original_stopped=false

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$temporary_started" == true ]]; then
    scripts/goal001/stop-vpp.sh || status=1
  fi
  if [[ -d /run/vpp-goal004-multiworker ]]; then
    [[ -f /run/vpp-goal004-multiworker/startup-goal001.conf ]] && unlink /run/vpp-goal004-multiworker/startup-goal001.conf
    rmdir /run/vpp-goal004-multiworker || status=1
  fi
  if [[ "$original_stopped" == true ]]; then
    scripts/goal001/start-vpp.sh || status=1
  fi
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf 'host default route 发生变化\n' >&2; status=1; }
  [[ $(ip -br addr show "$management_if") == "$before_management" ]] || { printf '%s 地址/状态发生变化\n' "$management_if" >&2; status=1; }
  [[ $(ip netns list) == "$before_namespaces" ]] || { printf 'host namespace 列表发生变化\n' >&2; status=1; }
  if [[ "$original_stopped" == true ]]; then
    [[ $(thread_count) -eq 1 ]] || { printf 'VPP 未恢复为单 main thread\n' >&2; status=1; }
  fi
  exit "$status"
}
trap cleanup EXIT

install -d -m 0700 /run/vpp-goal004-multiworker
cp deploy/vpp/startup-goal001.conf /run/vpp-goal004-multiworker/startup-goal001.conf
printf '\ncpu { workers 2 }\n' >> /run/vpp-goal004-multiworker/startup-goal001.conf

scripts/goal001/stop-vpp.sh
original_stopped=true
vpp -c /run/vpp-goal004-multiworker/startup-goal001.conf
temporary_started=true
for attempt in {1..200}; do
  if [[ -S "$CLI_SOCKET" && -S "$API_SOCKET" ]] && vppctl -s "$CLI_SOCKET" show version >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
require_vpp
[[ $(thread_count) -eq 3 ]] || die 'VPP 未启动两个 worker'
vppctl -s "$CLI_SOCKET" show threads

GOAL002_RX_WORKER=0 GOAL002_SERVER_RX_WORKER=1 GOAL002_SERVER_REPLY_DELAY=0.2 scripts/goal002/test-service.sh
printf '两个 worker 下 Goal 002 Service E2E 成功\n'
