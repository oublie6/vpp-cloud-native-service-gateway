#!/usr/bin/env bash
# 仅切换 Goal001 独立 VPP 的 CNAT 搜索路径；发行版插件文件始终不变。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
source scripts/goal001/topology-common.sh

action=${1:?用法：deploy-cnat.sh install <candidate.so> | rollback}
state_dir=/var/lib/vpp-goal006
plugin_dir=$state_dir/plugins
active=$state_dir/active.sha256
installed=$plugin_dir/cnat_plugin.so
system_plugin=/usr/lib/x86_64-linux-gnu/vpp_plugins/cnat_plugin.so
original_sha=fb00daba9badf8052499f2918b1fb03757bf939cab36bb61e94e763ec5ad0ffe
candidate_sha=d532c86af0805f0150ea9c5fa6b9cf81cec596fe13d4c941ea2e700f8816621b

require_root
require_vpp
[[ "$action" == install || "$action" == rollback ]] || die '仅支持 install 或 rollback'
[[ ! -e "$MARKER" && -z $(ip netns list) ]] || die '已有 namespace/Goal001 拓扑，拒绝切换'
[[ $(vppctl -s "$CLI_SOCKET" show interface | awk '$1 ~ /^(local0|tap[0-9]+)$/ {print $1}' | paste -sd ,) == local0 ]] || die 'VPP 不是仅有 local0 的干净基线'
inspect=$(go run ./cmd/goal002-inspect) || die 'VPP API 检查失败'
grep -Fq 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0' <<<"$inspect" || die 'VPP API 状态不是干净基线'
ss -xap | awk '/\/run\/vpp-goal001\/(api|cli)\.sock/ && $2 != "LISTEN" { bad=1 } END { exit bad }' || die 'VPP CLI/API 有其他客户端连接'
[[ -f "$system_plugin" && ! -L "$system_plugin" ]] || die '系统 CNAT plugin 文件类型异常'
[[ $(sha256sum "$system_plugin" | awk '{print $1}') == "$original_sha" ]] || die '系统 CNAT plugin hash 改变，拒绝覆盖未知状态'

before_route=$(ip -4 route show default)
management_if=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$before_route")
[[ -n "$management_if" ]] || die '无法识别管理接口'
before_management=$(ip -br addr show "$management_if")
for unit in goal004-worker-tcp-link kubelet containerd; do
  systemctl is-active --quiet "$unit" || die "$unit 当前不活跃，拒绝切换"
done
pid=$(<"$RUNTIME/vpp.pid")
if [[ "$action" == install ]]; then
  [[ $# -eq 2 ]] || die 'install 需要 candidate.so 路径'
  candidate=$2
  [[ -f "$candidate" && ! -L "$candidate" && $(stat -c %u "$candidate") == 0 ]] || die 'candidate 必须是 root 持有的普通文件'
  [[ $(sha256sum "$candidate" | awk '{print $1}') == "$candidate_sha" ]] || die 'candidate hash 与已验证构建不符'
  [[ ! -e "$active" ]] || die 'Goal006 CNAT 已激活；拒绝重复切换'
  grep -Fq "$system_plugin" "/proc/$pid/maps" || die '当前 VPP 未加载预期发行版 CNAT'
else
  [[ $# -eq 1 && -f "$active" && ! -L "$active" ]] || die '没有 Goal006 active marker，拒绝 rollback'
  [[ $(<"$active") == "$candidate_sha" ]] || die 'Goal006 active marker hash 不符'
  grep -Fq "$installed" "/proc/$pid/maps" || die '当前 VPP 未加载预期 Goal006 CNAT'
fi

install -d -m 0700 "$state_dir" "$plugin_dir"
if [[ ! -e "$state_dir/original-cnat_plugin.so" ]]; then
  install -m 0600 "$system_plugin" "$state_dir/original-cnat_plugin.so"
fi
[[ $(sha256sum "$state_dir/original-cnat_plugin.so" | awk '{print $1}') == "$original_sha" ]] || die 'root-only 原版插件备份 hash 不符'
if [[ "$action" == install ]]; then
  if [[ -e "$installed" ]]; then
    [[ ! -L "$installed" && $(sha256sum "$installed" | awk '{print $1}') == "$candidate_sha" ]] || die '专用目录已有未知 CNAT plugin'
  else
    temp_plugin=$(mktemp "$plugin_dir/.cnat_plugin.XXXXXX")
    install -m 0644 "$candidate" "$temp_plugin"
    [[ $(sha256sum "$temp_plugin" | awk '{print $1}') == "$candidate_sha" ]] || die '复制后的 candidate hash 不符'
    mv -n -- "$temp_plugin" "$installed"
  fi
fi

{ date -u; ip netns list; ip -br addr show "$management_if"; ip -4 route show default;
  vppctl -s "$CLI_SOCKET" show interface; vppctl -s "$CLI_SOCKET" show plugins | grep -i cnat;
  sha256sum "$system_plugin" "$installed"; } > "$state_dir/pre-switch.txt"
chmod 600 "$state_dir/pre-switch.txt"

previous_active=false
[[ "$action" == rollback ]] && previous_active=true
transition_started=false
completed=false
write_active() {
  local tmp
  tmp=$(mktemp "$state_dir/.active.XXXXXX")
  printf '%s\n' "$candidate_sha" > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$active"
}
restore_previous() {
  local current_pid
  if [[ -f "$RUNTIME/vpp.pid" ]]; then
    current_pid=$(<"$RUNTIME/vpp.pid")
    if [[ "$current_pid" =~ ^[0-9]+$ ]] && kill -0 "$current_pid" 2>/dev/null; then
      scripts/goal001/stop-vpp.sh || return 1
    fi
  fi
  if [[ "$previous_active" == true ]]; then
    write_active
  elif [[ -e "$active" ]]; then
    unlink "$active"
  fi
  scripts/goal001/start-vpp.sh
}
finish() {
  local status=$?
  trap - EXIT
  if (( status != 0 )) && [[ "$transition_started" == true && "$completed" == false ]]; then
    printf 'Goal006 切换失败，尝试恢复切换前 VPP\n' >&2
    restore_previous || { printf '原 VPP 恢复失败，请检查 %s/vpp.log\n' "$RUNTIME" >&2; status=1; }
  fi
  if [[ $(ip -4 route show default) != "$before_route" || $(ip -br addr show "$management_if") != "$before_management" ]]; then
    printf '宿主默认路由或管理接口状态发生变化\n' >&2
    status=1
  fi
  for unit in goal004-worker-tcp-link kubelet containerd; do
    systemctl is-active --quiet "$unit" || { printf '%s 不活跃\n' "$unit" >&2; status=1; }
  done
  exit "$status"
}
trap finish EXIT

transition_started=true
scripts/goal001/stop-vpp.sh
if [[ "$action" == install ]]; then
  write_active
else
  unlink "$active"
fi
scripts/goal001/start-vpp.sh
pid=$(<"$RUNTIME/vpp.pid")
if [[ "$action" == install ]]; then
  grep -Fq "$installed" "/proc/$pid/maps" || die 'VPP 没有加载 Goal006 候选 CNAT'
  GOAL006_REQUIRE_AUTO_RX=true GOAL006_ENABLE_INPUT_FEATURE=true \
    GOAL006_FIRST_REPLY_REGRESSION=true GOAL006_RESTART_REGRESSION=true \
    GOAL004_REPLY_DELAY=0 scripts/goal004/test-multiworker.sh > "$state_dir/deployment-e2e.log" 2>&1 || {
      tail -n 35 "$state_dir/deployment-e2e.log" >&2
      die '常驻候选 CNAT 的双 worker 回归失败'
    }
else
  grep -Fq "$system_plugin" "/proc/$pid/maps" || die 'rollback 后 VPP 未加载发行版 CNAT'
fi
go run ./cmd/goal002-inspect | grep -F 'interfaces=1 IPv4 routes=5 CNAT translations=0 sessions=0'
[[ -z $(ip netns list) && ! -e "$MARKER" ]] || die '切换后实验资源未清理'
[[ $(sha256sum "$system_plugin" | awk '{print $1}') == "$original_sha" ]] || die '系统发行版 CNAT 文件意外变化'
completed=true
printf 'Goal006 CNAT %s 成功；VPP PID=%s，系统插件 hash 未改变\n' "$action" "$pid"
