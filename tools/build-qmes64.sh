#!/bin/sh
# build-qmes64.sh — build the x86_64 qmes variant (qmes64.elf).
#
# qmes64 is the SAME interpreter source as qmes, plus bootstrap/qmes-w64.scm
# spliced in before the trailing (qmain):
#
#   cat rsc-prelude.scm qmes.scm qmes-w64.scm qmes-main.scm | rscA.elf
#     -> qmes64.qfasm  -> asm.elf -> qmes64.elf
#
# rsc's last-define-wins GV semantics make qmes-w64.scm's redefinitions shadow
# the 32-bit number layer at every call site, so qmes64 does 64-bit host
# arithmetic while staying an i386 process (asm.elf is unchanged; only the
# INTERPRETED numbers are 64-bit).
#
# The Stage 2..4 toolchain (scheme0/sc1/rscA/asm.elf) is shared with
# tools/build-qmes.sh and cached under build/qmes/; this script reuses it and
# only runs the final compile+assemble.  Run `make qmes` (or build-qmes.sh)
# once first to populate the cache.
#
# Usage: tools/build-qmes64.sh [qfitzah-path]
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
qfitzah=${1:-$repo_root/result/bin/qfitzah}
b="$repo_root/build/qmes"          # shared toolchain cache (build-qmes.sh)
b64="$repo_root/build/qmes64"
mkdir -p "$b64"
bootstrap="$repo_root/bootstrap"

need() { # need OUT IN...  -> true if OUT is missing or older than any IN
  out=$1; shift
  [ -f "$out" ] || return 0
  for f in "$@"; do [ "$f" -nt "$out" ] && return 0; done
  return 1
}

# Ensure the shared toolchain exists (rscA.elf + asm.elf + runtime).
if [ ! -x "$b/rscA.elf" ] || [ ! -x "$b/asm.elf" ]; then
    echo "[build-qmes64] priming shared toolchain via build-qmes.sh" >&2
    "$repo_root/tools/build-qmes.sh" "$qfitzah" >&2
fi

# --- rscB: a big-heap rsc compiler --------------------------------------------
# The cached rscA.elf is SC1-compiled and its ELF reserves only a 256 MiB cell
# BSS — enough for qmes.scm alone, but qmes.scm + qmes-w64.scm overflows it
# (rsc has no GC; the compile-time cell heap is a bump allocator).  A RSC-
# compiled rsc, by contrast, reserves the full 1568 MiB heap layout.  So we
# self-host once: rscA compiles rsc.scm -> rscB.qfasm (which carries rsc's big
# BSS reservation), assembled by asm.elf into rscB.elf.  rscB is byte-identical
# in behaviour to rscA (verified: it emits identical qmes.qfasm) but can compile
# the larger 64-bit variant.
if need "$b64/rscB.elf" "$b/rscA.elf" "$bootstrap/rsc.scm" \
        "$bootstrap/sc1-reader.scm" "$bootstrap/asm-runtime.flat" "$b/asm.elf"; then
    echo "[build-qmes64] self-hosting rscB.elf (big-heap rsc)" >&2
    cat "$bootstrap/sc1-reader.scm" "$bootstrap/rsc.scm" \
      | "$b/rscA.elf" > "$b64/rscB.qfasm"
    "$b/asm.elf" "$bootstrap/asm-runtime.flat" < "$b64/rscB.qfasm" > "$b64/rscB.elf"
    chmod +x "$b64/rscB.elf"
fi

echo "[build-qmes64] compiling (qmes.scm + qmes-w64.scm) -> qmes64.qfasm" >&2
cat "$bootstrap/rsc-prelude.scm" "$bootstrap/qmes.scm" \
    "$bootstrap/qmes-w64.scm" "$bootstrap/qmes-main.scm" \
  | "$b64/rscB.elf" > "$b64/qmes64.qfasm"

echo "[build-qmes64] assembling qmes64.qfasm -> qmes64.elf (asm.elf)" >&2
"$b/asm.elf" "$bootstrap/asm-runtime.flat" < "$b64/qmes64.qfasm" > "$repo_root/qmes64.elf"
chmod +x "$repo_root/qmes64.elf"
echo "[build-qmes64] wrote $repo_root/qmes64.elf" >&2
