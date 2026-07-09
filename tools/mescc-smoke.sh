#!/bin/sh
# mescc-smoke.sh — run GNU Mes's MesCC in compile-only (-S) mode over a C file
# under a chosen Scheme host (bin/mes-m2 or qmes.elf) and emit the .s (M1 text),
# with the determinism contract pinned (docs/mes-bootstrap.md, F1).
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

# Determinism contract: clear LANG, pin %version / MES_VERSION, fixed
# arena/stack, fixed MES_PREFIX + moduledir, no MES_DEBUG noise.  Run from
# repo_root so any path strings that reach the .s are stable.  The scrubbed
# `env -i ... mescc.scm --` driver is shared via tools/lib/mescc.sh; this
# script keeps its own arch/include/arena POLICY.
. "$repo_root/tools/lib/mescc.sh"
cd "$repo_root"
export MES_PREFIX="$root" MES_SRCDEST="$tp/" MES_MODULEDIR="$moduledir" MES_SCM="$tp/module/mescc.scm"
export MES_ARENA="${MES_ARENA-20000000}" MES_MAX_ARENA="${MES_MAX_ARENA-20000000}" MES_STACK="${MES_STACK-5000000}"
mescc_run "$host" \
    -- \
    -S -m 32 --arch=x86 \
    -D HAVE_CONFIG_H=1 \
    -I "$repo_root/build/include" \
    -I "$tp/include" \
    -o "$output" \
    "$input"
