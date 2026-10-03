#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/topology-common.sh"
require_root
require_vpp
[[ -f "$MARKER" ]] || die '请先运行 setup-topology.sh 与 configure-forwarding.sh'

# 本机 VPP 24.10 的 show hardware-interfaces 为 VIRTIO，show runtime
# 和 show node virtio-input 确认了真正的 polling input node。
vpp_cli 'show hardware-interfaces' | grep -Fq 'VIRTIO interface' || die '当前接口不是已验证的 VIRTIO TAP backend'
vpp_cli 'show node virtio-input' | grep -Fq 'type input, state polling' || die '未找到已验证的 virtio-input node'
vpp_cli 'clear trace' >/dev/null
vpp_cli 'clear errors' >/dev/null
vpp_cli 'trace add virtio-input 4' >/dev/null
ip netns exec "$CLIENT_NS" ping -n -c 1 -W 2 "${SERVER_ADDR%/*}" || die 'trace 触发 packet 未成功到达 server'
printf '%s\n' '=== show trace ==='
vpp_cli 'show trace'
printf '%s\n' '=== show errors ==='
vpp_cli 'show errors'
printf '%s\n' '=== show runtime ==='
vpp_cli 'show runtime'
printf '%s\n' '=== show threads ==='
vpp_cli 'show threads'
