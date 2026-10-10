#!/usr/bin/env bash
# Prepare pinned TinyCC and bootstrap libc source; no compiler is run here.
set -euo pipefail
if (( $# != 2 )); then
  echo "usage: $0 SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
cache=$(realpath "$1")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -- "$2"
out=$(realpath "$2")
bash "$b/blynn/export-source.sh" "$cache" blynn-bootstrap "$out/target"
bash "$b/blynn/export-source.sh" "$cache" gnu-mes "$out/mes"
bash "$b/blynn/export-source.sh" "$cache" tinycc "$out/tinycc"
(cd "$out/mes" && patch --batch --fuzz=0 -p1 < "$out/target/patches/upstreams/gnu-mes-libc-hcc-bootstrap.patch")
(cd "$out/tinycc" && patch --batch --fuzz=0 -p1 < "$out/target/patches/upstreams/tinycc-mescc-source.patch")
# compiler=gcc in upstream config.sh selects GNU-assembly libc sources for
# TinyCC; configure-lib.sh enumerates sources, and does not invoke GCC.
GNU_MES_DIR="$out/mes" MES_LIBC_ARCH=x86_64 OUT_DIR="$out/libc" \
BOOTSTRAP_LIB="$out/target/scripts/lib/bootstrap.sh" \
MES_STRTOD_SOURCE="$out/target/nix/sources/mes-libc/strtod.c" \
MES_LDEXP_SOURCE="$out/target/nix/sources/mes-libc/ldexp-ldexpl.c" \
MES_SETJMP_SOURCE="$out/target/nix/sources/mes-libc/x86_64-setjmp.c" \
MES_CONFIG_SOURCE="$out/target/nix/sources/mes-libc/config.h" \
  sh "$out/target/scripts/prepare-mes-libc.sh"
test -s "$out/libc/lib/libc.c"
sha256sum "$out/libc/lib/libc.c" "$out/libc/lib/crt1.c" > "$out/libc-source.sha256"
echo 'ok - pinned HCC/TinyCC and bootstrap libc source preparation'
