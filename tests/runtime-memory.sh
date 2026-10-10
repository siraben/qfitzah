#!/usr/bin/env bash
# Exercise reclamation and deterministic failure with a source-configured heap.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 SEED RSC_COMPILER" >&2
  exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
b=$root/bootstrap
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ulimit -c 0
printf '(Rule (GcHeapBytes) (X8 0 0 0 1 0 0 0 0))\n' > "$tmp/heap.qf1"
compile() {
  cat "$b/rsc-prelude.scm" "$1" | timeout 120s "$compiler" > "$tmp/program.qfasm"
  cat "$b/qfasm.qf1" "$b/runtime-support.qf1" "$b/gc.qf1" \
      "$b/io.qf1" "$b/control.qf1" "$b/lookup.qf1" "$tmp/heap.qf1" "$b/rsc-runtime.qf1" "$tmp/program.qfasm" \
    | timeout 120s "$seed" > "$tmp/program"
  chmod +x "$tmp/program"
}
compile "$root/tests/cases/rsc-gc.scm"
# A bounded native stack detects accidentally recursive marking or lost tails.
(ulimit -s 256; timeout 30s "$tmp/program") > "$tmp/actual"
diff -u "$root/tests/cases/rsc-gc.expected" "$tmp/actual"
echo 'ok - rsc-gc (64 KiB/arena, cycles, byte buffers, closures, static roots)'
compile "$root/tests/cases/rsc-gc-stats.scm"
timeout 30s "$tmp/program" > "$tmp/actual"
diff -u "$root/tests/cases/rsc-gc-stats.expected" "$tmp/actual"
echo 'ok - rsc-gc retained-space diagnostic (live buffers and reclamation)'
compile "$root/tests/cases/rsc-gc-atomic.scm"
timeout 30s "$tmp/program" > "$tmp/actual"
diff -u "$root/tests/cases/rsc-gc-atomic.expected" "$tmp/actual"
echo 'ok - rsc-gc byte contents do not retain pointer-shaped garbage'
compile "$root/tests/cases/rsc-gc-fragmentation.scm"
timeout 30s "$tmp/program" > "$tmp/actual"
diff -u "$root/tests/cases/rsc-gc-fragmentation.expected" "$tmp/actual"
echo 'ok - rsc-gc segregated arenas, cross-arena roots and reclaimed bump tails'

compile "$root/tests/cases/rsc-env-find.scm"
timeout 30s "$tmp/program" > "$tmp/actual"
diff -u "$root/tests/cases/rsc-env-find.expected" "$tmp/actual"
echo 'ok - native host lookup matches Scheme frames, fallback, slots and mutation'

expect_oom() {
  local expression=$1 status=0
  printf '%s\n' "$expression" > "$tmp/failure.scm"
  compile "$tmp/failure.scm"
  timeout 10s "$tmp/program" > "$tmp/actual" 2> "$tmp/error" || status=$?
  [[ $status == 1 && ! -s "$tmp/actual" ]] || {
    echo "FAIL memory rejection ($status): $expression" >&2
    exit 1
  }
  printf 'rsc: out of memory\n' > "$tmp/expected"
  diff -u "$tmp/expected" "$tmp/error"
}
expect_oom '(make-string -1)'
expect_oom '(make-vector -1)'
expect_oom '(make-string 536870911)'
expect_oom '(make-vector 536870911)'
expect_oom '(make-string 65536)'
# An unbounded LIVE list must fail cleanly rather than collect its live cells.
expect_oom '(define (fill xs) (fill (cons (make-string 1024) xs))) (fill (quote ()))'
echo 'ok - rsc-allocation-failure (negative, oversized, overflow, live exhaustion)'
