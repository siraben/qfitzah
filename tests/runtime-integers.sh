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
cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" \
    "$b/rsc-integers.scm" "$root/tests/cases/rsc-integers.scm" \
  | timeout 120s "$compiler" > "$tmp/program.qfasm"
printf '(Rule (GcHeapBytes) (X8 0 0 0 4 0 0 0 0))\n' > "$tmp/heap.qf1"
timeout 120s bash "$b/assemble.sh" "$seed" rsc "$tmp/program.qfasm" "$tmp/heap.qf1" > "$tmp/program"
chmod +x "$tmp/program"
timeout 60s "$tmp/program" > "$tmp/actual"
diff -u "$root/tests/cases/rsc-integers.expected" "$tmp/actual"
echo 'ok - rsc-integers (wide signed arithmetic, division, radix, bitwise, GC)'
