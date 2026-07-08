#!/bin/sh
# regen.sh -- build a dialect generator (bootstrap/gen-<name>.scm) with the
# already-built rsc toolchain and run it, capturing its stdout.
#
# These generators are the in-dialect replacements for the retired
# tools/generate_*.py: each emits a committed generated artifact BYTE-IDENTICAL
# to the Python it replaced.  They are dev-time regeneration tools, run on
# rsc.elf (built by `make qmes`); the bootstrap itself uses the committed
# artifacts directly, so there is no bootstrap circularity.
#
# Usage:
#   tools/regen.sh build <name>            # compile+assemble gen-<name>.scm
#   tools/regen.sh run <name> [args...]    # run the built generator
#   tools/regen.sh gen <name> [args...]    # build (if needed) then run
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
bootstrap="$repo_root/bootstrap"
b="$repo_root/build/qmes"
RSC="$b/rscA.elf"
ASM="$b/asm.elf"
FLAT="$bootstrap/asm-runtime.flat"

build_one() {
  name=$1
  src="$bootstrap/gen-$name.scm"
  [ -f "$src" ] || { echo "regen: no such generator: $src" >&2; exit 1; }
  out="$b/gen-$name.elf"
  if [ ! -f "$out" ] || [ "$src" -nt "$out" ] || [ "$bootstrap/rsc-prelude.scm" -nt "$out" ]; then
    echo "[regen] compiling gen-$name.scm" >&2
    cat "$bootstrap/rsc-prelude.scm" "$src" | "$RSC" > "$b/gen-$name.qfasm"
    "$ASM" "$FLAT" < "$b/gen-$name.qfasm" > "$out"
    chmod +x "$out"
  fi
}

cmd=${1:?usage: regen.sh build|run|gen <name> [args...]}
shift
case "$cmd" in
  build) build_one "$1" ;;
  run)   name=$1; shift; "$b/gen-$name.elf" "$@" ;;
  gen)   name=$1; shift; build_one "$name"; "$b/gen-$name.elf" "$@" ;;
  *) echo "regen: unknown command: $cmd" >&2; exit 1 ;;
esac
