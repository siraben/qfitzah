#!/usr/bin/env bash
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
cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$root/tests/cases/rsc-control.scm" \
  | timeout 120s "$compiler" > "$tmp/program.qfasm"
printf '(Rule (GcHeapBytes) (X8 0 0 0 1 0 0 0 0))\n' > "$tmp/heap.qf1"
cat "$b/qfasm.qf1" "$b/runtime-support.qf1" "$b/gc.qf1" "$b/io.qf1" \
    "$b/control.qf1" "$b/lookup.qf1" "$tmp/heap.qf1" "$b/rsc-runtime.qf1" "$tmp/program.qfasm" \
  | timeout 120s "$seed" > "$tmp/program"
chmod +x "$tmp/program"
(ulimit -s 256; timeout 30s "$tmp/program") > "$tmp/actual"
diff -u "$root/tests/cases/rsc-control.expected" "$tmp/actual"
echo 'ok - rsc-control (multi-shot continuations, winding, exceptions, fluids, GC)'
