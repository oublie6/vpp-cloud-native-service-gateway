#!/usr/bin/env bash
# 渲染 Goal001 独立 VPP 配置；只有明确激活且 hash 匹配时加载 Goal006 CNAT。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base=$repo_dir/deploy/vpp/startup-goal001.conf
active=/var/lib/vpp-goal006/active.sha256
plugin_dir=/var/lib/vpp-goal006/plugins
output=${1:?需要输出路径}
override=${2:-}

(( EUID == 0 )) || { printf '渲染 VPP 配置需要 root\n' >&2; exit 1; }
case "$output" in
  /run/vpp-goal001/startup-goal001.conf|/run/vpp-goal004-multiworker/startup-goal001.conf) ;;
  *) printf '拒绝写入非本 Goal 配置路径：%s\n' "$output" >&2; exit 1 ;;
esac

if [[ -n "$override" ]]; then
  [[ "$override" == /tmp/goal006-cnat.* ]] || { printf '隔离插件路径必须在 /tmp/goal006-cnat.*\n' >&2; exit 1; }
  plugin_dir=$override
elif [[ -e "$active" ]]; then
  [[ -f "$active" && ! -L "$active" ]] || { printf 'Goal006 active marker 类型错误\n' >&2; exit 1; }
  expected=$(<"$active")
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { printf 'Goal006 active marker hash 无效\n' >&2; exit 1; }
  actual=$(sha256sum "$plugin_dir/cnat_plugin.so" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { printf 'Goal006 CNAT plugin hash 不匹配\n' >&2; exit 1; }
else
  plugin_dir=
fi

tmp=$(mktemp "${output}.XXXXXX")
if [[ -n "$plugin_dir" ]]; then
  [[ -f "$plugin_dir/cnat_plugin.so" && ! -L "$plugin_dir/cnat_plugin.so" ]] || {
    printf 'Goal006 CNAT plugin 不存在或是 symlink：%s\n' "$plugin_dir" >&2
    unlink "$tmp"
    exit 1
  }
  [[ $(grep -c '^plugins {$' "$base") -eq 1 ]] || { printf 'VPP base plugin stanza 不唯一\n' >&2; unlink "$tmp"; exit 1; }
  awk -v dir="$plugin_dir" '/^plugins \{$/ { print; print "  path " dir; next } { print }' "$base" > "$tmp"
else
  cp "$base" "$tmp"
fi
chmod 600 "$tmp"
mv -f -- "$tmp" "$output"
