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
    "$b/rsc-integers.scm" "$b/rsc-reader.scm" "$root/tests/cases/rsc-reader.scm" \
  | timeout 120s "$compiler" > "$tmp/program.qfasm"
timeout 120s bash "$b/assemble.sh" "$seed" rsc "$tmp/program.qfasm" > "$tmp/program"
chmod +x "$tmp/program"
timeout 30s "$tmp/program" < "$root/tests/cases/rsc-reader-input.scm" > "$tmp/actual"
diff -u "$root/tests/cases/rsc-reader.expected" "$tmp/actual"
echo 'ok - rsc-reader (ports, exact integers, vectors, keywords, escapes, rejection)'
