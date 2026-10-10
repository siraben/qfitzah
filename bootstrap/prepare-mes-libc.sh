#!/usr/bin/env bash
# Prepare GNU Mes's Linux/i386 libc headers without configure or compiled input.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 MES_SOURCE NEW_DIRECTORY" >&2; exit 2
fi
source=$(realpath "$1")
test -f "$source/include/mes/lib-mini.h"
mkdir -- "$2"
out=$(realpath "$2")
cp -RL "$source/." "$out/"
mkdir -p "$out/include/arch"
for header in kernel-stat.h signal.h syscall.h; do
  cp "$source/include/linux/x86/$header" "$out/include/arch/$header"
done
# The same minimal configuration used by live-bootstrap's Mes 0.27.1 pass.
printf '#undef SYSTEM_LIBC\n#define MES_VERSION "0.27.1"\n' > "$out/include/mes/config.h"
printf '%s\n' "$out"
