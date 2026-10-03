#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/topology-common.sh"
require_root
if [[ ! -f "$MARKER" ]]; then
  printf 'Goal 001 拓扑不存在；未删除任何对象\n'
  exit 0
fi
[[ "$(<"$MARKER")" == goal001-tap-topology ]] || die 'ownership marker 内容不匹配，拒绝清理'
require_vpp
for id in "$CLIENT_TAP_ID" "$SERVER_TAP_ID"; do
  if vpp_cli 'show interface' | grep -Eq "^[[:space:]]*tap${id}[[:space:]]"; then
    vpp_cli "delete tap tap$id" >/dev/null
  fi
done
for ns in "$CLIENT_NS" "$SERVER_NS"; do
  if ip netns list | grep -Eq "^${ns}( |$)"; then
    ip netns del "$ns" || die "删除 namespace $ns 失败"
  fi
done
rm -- "$MARKER"
printf 'Goal 001 TAP/namespace 已清理；原始状态记录：%s\n' "$BEFORE"
