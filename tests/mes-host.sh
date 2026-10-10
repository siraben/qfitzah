#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 SEED RSC_COMPILER" >&2
  exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  local status=$?
  if [[ $status == 0 ]]; then rm -rf "$tmp"
  else echo "mes-host test artifacts retained: $tmp" >&2
  fi
}
trap cleanup EXIT
ulimit -c 0
# Current file-based host fixtures exhaust 1 MiB, also without binding indexes.
# 2 MiB per arena remains far below allocation volume and forces collection.
printf '(Rule (GcHeapBytes) (X8 0 0 2 0 0 0 0 0))\n' > "$tmp/heap.qf1"
timeout 600s bash "$root/bootstrap/build-mes-host.sh" "$seed" "$compiler" "$tmp/build" "$tmp/heap.qf1"
for test in eval derived identifiers modules library; do
  (ulimit -s 512; timeout 60s "$tmp/build/mes-host" -L "$root/tests/modules" \
    "$root/tests/cases/mes-host-$test.scm") > "$tmp/actual"
  diff -u "$root/tests/cases/mes-host-$test.expected" "$tmp/actual"
  echo "ok - mes-host $test (2 MiB/arena, 512 KiB stack)"
done
