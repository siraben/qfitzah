#!/bin/sh
# mescc-smoke.sh — run GNU Mes's MesCC in compile-only (-S) mode over a C file
# under a chosen Scheme host (bin/mes-m2 or qmes.elf) and emit the .s (M1 text),
# with the determinism contract pinned (mes-bootstrap-plan §5, F1).
#
# Usage: tools/mescc-smoke.sh HOST INPUT.c OUTPUT.s
#   HOST     path to the Mes interpreter (e.g. bin/mes-m2 or ./qmes.elf)
#   INPUT.c  C source (path relative to repo root or absolute)
#   OUTPUT.s destination assembly file
#
# The invocation mirrors third_party/mes/scripts/mescc.{in,scm.in}:
#   $HOST --no-auto-compile -e main -L $moduledir mescc.scm -- <mescc args>
# with -S -m 32 --arch=x86 -D HAVE_CONFIG_H=1 and the mes include tree.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tp="$repo_root/third_party/mes"
root="$repo_root/build/mesroot"          # merged module root (has nyacc)
moduledir="$root/mes/module"

host=$1
input=$2
output=$3

# Ensure the merged root (with vendored nyacc) exists.
[ -d "$moduledir/nyacc/lang/c99" ] || "$repo_root/tools/make-mesroot.sh" >/dev/null

# Generate <mes/config.h> (found via -I build/include) for -D HAVE_CONFIG_H=1.
# MES_VERSION must match the reference build's config.h (0.27.1) for byte parity.
cfg="$repo_root/build/include/mes/config.h"
if [ ! -f "$cfg" ]; then
    mkdir -p "$repo_root/build/include/mes"
    ver=$(sed -n 's/^VERSION=//p' "$tp/configure.sh" | head -1)
    printf '#undef SYSTEM_LIBC\n#define MES_VERSION "%s"\n' "${ver:-0.27.1}" > "$cfg"
fi

mkdir -p "$(dirname "$output")"

# Determinism contract (plan §5): clear LANG, pin %version / MES_VERSION,
# fixed arena/stack, fixed MES_PREFIX + moduledir, no MES_DEBUG noise.
# Run from repo_root so any path strings that reach the .s are stable.
cd "$repo_root"
exec env -i \
    PATH="$PATH" \
    LANG= \
    MES_DEBUG=0 \
    %version=0.27.1 \
    MES_ARENA="${MES_ARENA-20000000}" \
    MES_MAX_ARENA="${MES_MAX_ARENA-20000000}" \
    MES_STACK="${MES_STACK-5000000}" \
    MES_PREFIX="$root" \
    srcdest="$tp/" \
    GUILE_LOAD_PATH="$moduledir" \
    "$host" \
        --no-auto-compile \
        -e main \
        "$tp/module/mescc.scm" \
        -- \
        -S -m 32 --arch=x86 \
        -D HAVE_CONFIG_H=1 \
        -I "$repo_root/build/include" \
        -I "$tp/include" \
        -o "$output" \
        "$input"
