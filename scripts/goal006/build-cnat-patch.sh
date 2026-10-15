#!/usr/bin/env bash
# 仅在 /tmp 构建 VPP v24.10 CNAT 候选插件；绝不安装到系统 plugin 目录。
set -Eeuo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source_commit=cfa0953251cbab435307baf3dcd249fd95afaf1f
build_dir=$(mktemp -d /tmp/goal006-cnat.XXXXXX)
source_dir=$build_dir/src/plugins/cnat
mkdir -p "$source_dir"
printf 'Goal006 isolated build directory: %s\n' "$build_dir"

files=(cnat.api cnat_api.c cnat_bihash.h cnat_client.c cnat_client.h
  cnat_error.def cnat_inline.h cnat_maglev.c cnat_maglev.h cnat_node.h
  cnat_node_feature.c cnat_node_snat.c cnat_node_vip.c cnat_scanner.c
  cnat_scanner.h cnat_session.c cnat_session.h cnat_snat_policy.c
  cnat_snat_policy.h cnat_src_policy.c cnat_src_policy.h
  cnat_translation.c cnat_translation.h cnat_types.c cnat_types.h)
for file in "${files[@]}"; do
  curl --fail --show-error --silent --location \
    "https://raw.githubusercontent.com/FDio/vpp/$source_commit/src/plugins/cnat/$file" \
    --output "$source_dir/$file"
done
# 与本机 VPP 24.10 release 分析时读取的源文件核对，避免误用移动分支。
expected=a551124dba863b01598ec60d2073d787a67d7a32a3ebf9b4b5255e739848ea63
actual=$(sha256sum "$source_dir/cnat_node_vip.c" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { printf 'CNAT source SHA256 不匹配：%s\n' "$actual" >&2; exit 1; }
patch --batch --forward --directory "$build_dir" --strip 1 \
  --input "$repo_dir/patches/goal006-cnat-return-input.patch"
cat > "$build_dir/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(goal006_cnat C)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
find_package(VPP REQUIRED)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/plugins)
include_directories(${CMAKE_BINARY_DIR}/src/plugins)
add_vpp_plugin(cnat
  SOURCES
  src/plugins/cnat/cnat_api.c
  src/plugins/cnat/cnat_client.c
  src/plugins/cnat/cnat_node_snat.c
  src/plugins/cnat/cnat_node_vip.c
  src/plugins/cnat/cnat_node_feature.c
  src/plugins/cnat/cnat_scanner.c
  src/plugins/cnat/cnat_session.c
  src/plugins/cnat/cnat_translation.c
  src/plugins/cnat/cnat_types.c
  src/plugins/cnat/cnat_snat_policy.c
  src/plugins/cnat/cnat_src_policy.c
  src/plugins/cnat/cnat_maglev.c
  API_FILES src/plugins/cnat/cnat.api
  COMPONENT vpp-plugin-core
)
CMAKE
cmake -S "$build_dir" -B "$build_dir/build" -G Ninja
cmake --build "$build_dir/build"
[[ -f "$build_dir/build/vpp_plugins/cnat_plugin.so" ]] || { printf '未生成 CNAT plugin\n' >&2; exit 1; }
printf 'GOAL006_PLUGIN_PATH=%s\n' "$build_dir/build/vpp_plugins"
