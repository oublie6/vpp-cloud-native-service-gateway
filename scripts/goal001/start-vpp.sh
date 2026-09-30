#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
config="$repo_dir/deploy/vpp/startup-goal001.conf"
runtime=/run/vpp-goal001

if (( EUID != 0 )); then
  printf '需要 root 启动 VPP\n' >&2
  exit 1
fi
if systemctl is-active --quiet vpp; then
  printf '系统 VPP service 正在运行；请先停止，避免实例冲突\n' >&2
  exit 1
fi
if [[ -f "$runtime/vpp.pid" ]]; then
  old_pid=$(<"$runtime/vpp.pid")
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    if [[ -r "/proc/$old_pid/cmdline" ]] \
      && tr '\0' ' ' < "/proc/$old_pid/cmdline" | grep -Fq "$config"; then
      printf 'Goal 001 VPP 已在运行: PID %s\n' "$old_pid"
      exit 0
    fi
    printf 'pidfile 指向其他进程，拒绝启动: PID %s\n' "$old_pid" >&2
    exit 1
  fi
  rm -f -- "$runtime/vpp.pid"
fi
install -d -m 0755 "$runtime"
for socket in "$runtime/cli.sock" "$runtime/api.sock"; do
  if [[ -S "$socket" ]]; then
    rm -f -- "$socket"
  fi
done
vpp -c "$config"
for attempt in {1..50}; do
  if [[ -f "$runtime/vpp.pid" ]] && kill -0 "$(<"$runtime/vpp.pid")" 2>/dev/null \
    && [[ -S "$runtime/cli.sock" && -S "$runtime/api.sock" ]]; then
    printf 'VPP 已启动: CLI=%s Binary API=%s\n' "$runtime/cli.sock" "$runtime/api.sock"
    exit 0
  fi
  sleep 0.1
done
printf 'VPP 未建立预期 socket；请查看 %s/vpp.log\n' "$runtime" >&2
exit 1
