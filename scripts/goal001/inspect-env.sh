#!/usr/bin/env bash
set -euo pipefail

source /etc/os-release
printf 'OS: %s %s (%s)\n' "$NAME" "$VERSION_ID" "$VERSION_CODENAME"
printf 'Kernel: %s\n' "$(uname -r)"
printf 'Arch: %s\n' "$(uname -m)"
if command -v go >/dev/null 2>&1; then go version; else printf 'Go: absent\n'; fi
if dpkg-query -W -f='${Version}\n' vpp 2>/dev/null; then
  printf 'VPP package: installed\n'
else
  printf 'VPP package: absent\n'
fi
printf 'HugePages: %s\n' "$(sysctl -n vm.nr_hugepages)"
