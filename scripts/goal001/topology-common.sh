#!/usr/bin/env bash
# Goal 001 软件拓扑的唯一命名与地址来源。
set -euo pipefail

RUNTIME=/run/vpp-goal001
CLI_SOCKET=$RUNTIME/cli.sock
MARKER=$RUNTIME/topology-owned
BEFORE=$RUNTIME/topology-before.txt
CLIENT_NS=g001-client
SERVER_NS=g001-server
CLIENT_HOST_IF=g001tapc
SERVER_HOST_IF=g001taps
CLIENT_TAP_ID=101
SERVER_TAP_ID=102
CLIENT_VPP_IF=tap101
SERVER_VPP_IF=tap102
CLIENT_ADDR=10.10.1.2/24
SERVER_ADDR=10.10.2.2/24
CLIENT_GW=10.10.1.1
SERVER_GW=10.10.2.1

die() { printf 'Goal 001 topology: %s\n' "$*" >&2; exit 1; }
require_root() { (( EUID == 0 )) || die '需要 root 权限'; }
require_vpp() {
  [[ -S "$CLI_SOCKET" && -f "$RUNTIME/vpp.pid" ]] || die "VPP 未运行或 CLI socket 不存在：$CLI_SOCKET"
  local pid
  pid=$(<"$RUNTIME/vpp.pid")
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || die 'Goal 001 VPP pid 无效或进程未运行'
  [[ -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq 'startup-goal001.conf' || die 'pidfile 不是 Goal 001 VPP'
}
vpp_cli() {
  local result
  result=$(vppctl -s "$CLI_SOCKET" "$@") || die "VPP CLI 失败：$*"
  if [[ "$result" == *'unknown input'* || "$result" == *'failed'* || "$result" == *'error:'* ]]; then
    die "VPP CLI 拒绝 $*: $result"
  fi
  printf '%s\n' "$result"
}
