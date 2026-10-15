#!/usr/bin/env bash
# 手工隔离测试：只注入 Goal005 独立 VPP/plugin 的失败，不碰节点链路。
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
(( EUID == 0 )) || { printf '需要 root\n' >&2; exit 1; }
plugin=/usr/lib/x86_64-linux-gnu/vpp_plugins/goal005_observe_plugin.so
[[ ! -e "$plugin" && ! -e /run/vpp-goal001/topology-owned ]] || { printf 'Goal005 资源已存在，拒绝接管\n' >&2; exit 1; }
log_dir=${GOAL006_LOG_DIR:-$(mktemp -d /tmp/goal006-plugin-rollback.XXXXXX)}
[[ -d "$log_dir" && -O "$log_dir" ]] || { printf '日志目录不可用\n' >&2; exit 1; }
chmod 700 "$log_dir"
before_route=$(ip -4 route show default)
management_if=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$before_route")
[[ -n "$management_if" ]] || exit 1
before_management=$(ip -o -4 addr show dev "$management_if")
before_namespaces=$(ip netns list)
before_services=$(systemctl is-active goal004-worker-tcp-link kubelet containerd)
verify_restored() {
  local stage=$1
  [[ $(ip -4 route show default) == "$before_route" ]] || { printf '%s: 默认路由变化\n' "$stage" >&2; return 1; }
  [[ $(ip -o -4 addr show dev "$management_if") == "$before_management" ]] || { printf '%s: 管理接口变化\n' "$stage" >&2; return 1; }
  [[ $(ip netns list) == "$before_namespaces" ]] || { printf '%s: namespace 变化\n' "$stage" >&2; return 1; }
  [[ $(systemctl is-active goal004-worker-tcp-link kubelet containerd) == "$before_services" ]] || { printf '%s: 节点服务变化\n' "$stage" >&2; return 1; }
  [[ ! -e "$plugin" && ! -e /run/vpp-goal001/topology-owned ]] || { printf '%s: plugin/marker 残留\n' "$stage" >&2; return 1; }
  [[ -S /run/vpp-goal001/cli.sock && -S /run/vpp-goal001/api.sock ]] || { printf '%s: VPP socket 缺失\n' "$stage" >&2; return 1; }
  pid=$(< /run/vpp-goal001/vpp.pid)
  kill -0 "$pid" || return 1
  vppctl -s /run/vpp-goal001/cli.sock show version >/dev/null
  plugins=$(vppctl -s /run/vpp-goal001/cli.sock show plugins)
  ! grep -Fq goal005_observe_plugin.so <<<"$plugins"
  [[ $(vppctl -s /run/vpp-goal001/cli.sock show interface | awk '$1 ~ /^tap10[12]$/ { n++ } END { print n+0 }') -eq 0 ]] || return 1
  inspect=$(go run ./cmd/goal002-inspect)
  grep -Fq 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0' <<<"$inspect"
  printf '%s: VPP PID=%s, socket/plugin/TAP/namespace/route/management/node services restored\n' "$stage" "$pid"
}
verify_restored before
for stage in build install start api-enable traffic; do
  before_pid=$(< /run/vpp-goal001/vpp.pid)
  if GOAL005_FAIL_AT="$stage" scripts/goal005/test-plugin.sh > "$log_dir/$stage.log" 2>&1; then
    printf '%s 注入意外成功\n' "$stage" >&2
    exit 1
  fi
  verify_restored "$stage"
  if [[ "$stage" == build ]]; then
    [[ $(< /run/vpp-goal001/vpp.pid) == "$before_pid" ]] || { printf 'build 失败改变了原 VPP PID\n' >&2; exit 1; }
  fi
  grep -Fq "注入：" "$log_dir/$stage.log" || { printf '%s 未触发预期注入\n' "$stage" >&2; exit 1; }
done
scripts/goal005/test-plugin.sh > "$log_dir/normal.log" 2>&1
verify_restored normal
printf 'Goal006 Goal005 回滚与正常流量验证通过；日志目录：%s\n' "$log_dir"
