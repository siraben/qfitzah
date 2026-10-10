#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "usage: $0 SEED RSC" >&2; exit 2; fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
b=$root/bootstrap
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" \
    "$b/rsc-integers.scm" "$b/rsc-reader.scm" \
    "$b/mes-host/identifiers.scm" "$b/mes-host/environment.scm" \
    "$b/mes-host/evaluate.scm" "$b/mes-host/syntax.scm" \
    "$b/mes-host/analyze.scm" "$root/tests/cases/mes-host-analyze-core.scm" \
  | timeout 120s "$compiler" | cat > "$tmp/program.qfasm"
printf '(Rule (GcHeapBytes) (X8 0 0 1 0 0 0 0 0))\n' > "$tmp/heap.qf1"
bash "$b/assemble.sh" "$seed" rsc "$tmp/program.qfasm" "$tmp/heap.qf1" > "$tmp/program"
chmod +x "$tmp/program"
env -u QFITZAH_DISABLE_ANALYSIS timeout 30s "$tmp/program" > "$tmp/actual"
diff -u "$root/tests/cases/mes-host-analyze-core.expected" "$tmp/actual"
echo 'ok - analyzed core/reference equivalence, fallback, live bindings and continuations'
