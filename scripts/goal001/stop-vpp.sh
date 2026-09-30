#!/usr/bin/env bash
set -euo pipefail

runtime=/run/vpp-goal001
pidfile="$runtime/vpp.pid"
if (( EUID != 0 )); then
  printf '需要 root 停止 VPP\n' >&2
  exit 1
fi
if [[ ! -f "$pidfile" ]]; then
  printf 'Goal 001 VPP 未运行（无 pidfile）\n'
  exit 0
fi
pid=$(<"$pidfile")
if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ ! -r "/proc/$pid/cmdline" ]]; then
  printf 'pidfile 无效或进程已退出，请检查 %s\n' "$pidfile" >&2
  exit 1
fi
if ! tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq 'startup-goal001.conf'; then
  printf 'PID %s 不是 Goal 001 VPP，拒绝停止\n' "$pid" >&2
  exit 1
fi
kill "$pid"
for attempt in {1..50}; do
  if [[ ! -d "/proc/$pid" ]]; then
    for socket in "$runtime/cli.sock" "$runtime/api.sock"; do
      if [[ -S "$socket" ]]; then rm -f -- "$socket"; fi
    done
    rm -f -- "$pidfile"
    printf 'Goal 001 VPP 已停止\n'
    exit 0
  fi
  sleep 0.1
done
printf 'PID %s 未在预期时间退出\n' "$pid" >&2
exit 1
