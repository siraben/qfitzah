#!/bin/sh
# run-torture.sh — the mandatory w64 differential gate (design §5/§6).
# Runs tests/mes-64/w64-ops.scm (every w64 builtin x corner values x shift
# counts, plus number->string radix 2/8/10/16, string->number, #x/#b/#o reader
# literals, eqv?/assv on numbers) under BOTH ./qmes64.elf and bin/mes-m2-64 and
# byte-compares stdout.  mes-m2-64 defines truth for every corner.  This MUST
# pass before any MesCC F1-64 sweep.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
root="$repo/build/mesroot"
[ -d "$root/mes/module" ] || "$repo/tools/make-mesroot.sh" >/dev/null
[ -x "$repo/qmes64.elf" ]    || { echo "run-torture: build qmes64 first (tools/build-qmes64.sh)" >&2; exit 2; }
[ -x "$repo/bin/mes-m2-64" ] || { echo "run-torture: need bin/mes-m2-64 (ARCH=x86_64 make mes-reference)" >&2; exit 2; }
t="$repo/tests/mes-64/w64-ops.scm"
o="$repo/build/mes-64"; mkdir -p "$o"

echo "torture: sweeping bin/mes-m2-64 (reference truth) ..." >&2
env -i MES_PREFIX="$root" MES_ARENA=100000000 MES_MAX_ARENA=100000000 MES_STACK=8000000 \
    %version=0.27.1 GUILE_LOAD_PATH="$root/mes/module" "$repo/bin/mes-m2-64" "$t" > "$o/ref.out"
echo "torture: sweeping ./qmes64.elf (interpreted + w64-in-Scheme) ..." >&2
env -i MES_PREFIX="$root" MES_ARENA=50000000 MES_MAX_ARENA=50000000 MES_STACK=8000000 \
    %version=0.27.1 %arch=x86_64 GUILE_LOAD_PATH="$root/mes/module" "$repo/qmes64.elf" "$t" > "$o/qmes.out"

if cmp -s "$o/ref.out" "$o/qmes.out"; then
    echo "torture: BYTE-EXACT ($(wc -l < "$o/ref.out") lines) — qmes64 == mes-m2-64"
else
    echo "torture: DIVERGE:" >&2
    diff "$o/ref.out" "$o/qmes.out" | head -40 >&2
    exit 1
fi
