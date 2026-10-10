#!/usr/bin/env bash
# Prepare verified bootstrap TCC source; no configure or host compilation.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 TCC_SOURCE NEW_DIRECTORY" >&2; exit 2
fi
source=$(realpath "$1")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test -f "$source/tcc.c"
test -f "$source/tcctools.c"
mkdir -- "$2"
out=$(realpath "$2")
cp -RL "$source/." "$out/"
# live-bootstrap's paired remove-fileopen/addback-fileopen patches, combined.
patch --batch --forward --fuzz=0 -d "$out" -p1 < "$b/upstream/patches/tcc-ar-open.patch" >&2
# Bootstrap configuration comes from explicit compiler -D flags, not configure.
printf '/* Bootstrap configuration is supplied by compiler flags. */\n' > "$out/config.h"
printf '%s\n' "$out"
