#!/bin/sh
# regen-verify.sh -- prove every committed generated artifact is reproduced
# BYTE-IDENTICALLY by its in-dialect generator (bootstrap/gen-*.scm), the
# replacements for the retired tools/generate_*.py.  Requires the rsc toolchain
# under build/qmes (run `make qmes` first); the generators are compiled by
# rscA.elf and assembled by asm.elf, then run, and their stdout is cmp'd against
# the committed file.
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
regen="$repo_root/tools/regen.sh"
bootstrap="$repo_root/bootstrap"
cases="$repo_root/tests/cases"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <label> <committed-file> <generator-name> [args...]
  label=$1; want=$2; name=$3; shift 3
  "$regen" gen "$name" "$@" > "$tmp/out" 2>"$tmp/err" || {
    echo "FAIL $label: generator errored"; cat "$tmp/err" >&2; fail=1; return; }
  if cmp -s "$want" "$tmp/out"; then
    echo "ok   $label byte-identical"
  else
    echo "FAIL $label differs from $want"; fail=1
  fi
}

# One build per generator (regen.sh caches by mtime); pass args for variants.
check "qfasm.qf1"           "$bootstrap/qfasm.qf1"           qfasm
check "scheme0.qfasm"       "$bootstrap/scheme0.qfasm"       scheme0
check "sc1-runtime.qf1"     "$bootstrap/sc1-runtime.qf1"     sc1-runtime
check "sc1-asm-runtime.flat" "$bootstrap/sc1-asm-runtime.flat" sc1-runtime --flat
check "rsc-runtime.qf1"     "$bootstrap/rsc-runtime.qf1"     rsc-runtime
check "asm-runtime.flat"    "$bootstrap/asm-runtime.flat"    rsc-runtime --flat
check "qfasm-exit42.qfasm"  "$cases/qfasm-exit42.qfasm"      qfasm-tests exit42-qfasm
check "qfasm-exit42.hex"    "$cases/qfasm-exit42.hex"        qfasm-tests exit42-hex
check "qfasm-exit42.status" "$cases/qfasm-exit42.status"     qfasm-tests exit42-status
check "qfasm-arith.qfasm"   "$cases/qfasm-arith.qfasm"       qfasm-tests arith-qfasm
check "qfasm-arith.out"     "$cases/qfasm-arith.out"         qfasm-tests arith-out
check "qfasm-big.qfasm"     "$cases/qfasm-big.qfasm"         qfasm-tests big-qfasm
check "qfasm-big.hex"       "$cases/qfasm-big.hex"           qfasm-tests big-hex
check "qfasm-big.status"    "$cases/qfasm-big.status"        qfasm-tests big-status

if [ "$fail" = 0 ]; then
  echo "regen-verify: all committed generated artifacts reproduced byte-identically"
else
  echo "regen-verify: MISMATCH" >&2; exit 1
fi
