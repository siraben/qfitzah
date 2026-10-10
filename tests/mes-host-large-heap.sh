#!/usr/bin/env bash
# Check the MesCC host profile and its larger ELF mapping using source tools.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 SEED RSC_COMPILER" >&2; exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-host-memory.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "heap artifacts: $work" >&2; fi' EXIT
ulimit -c 0
timeout 600s bash "$root/bootstrap/build-mes-host.sh" "$seed" "$compiler" "$work/large"
timeout 120s "$work/large/mes-host" "$root/tests/cases/mes-host-large-heap.scm" > "$work/large.out"
grep -qx 'ok - 160 MiB live buffers survive collection' "$work/large.out"
# Same source, ordinary 128 MiB/arena runtime: buffers exceed their arena.
# Checked exhaustion, not SIGSEGV, despite unused small-object capacity.
bash "$root/bootstrap/assemble.sh" "$seed" rsc "$work/large/mes-host.qfasm" > "$work/small"
chmod +x "$work/small"
status=0
timeout 120s "$work/small" "$root/tests/cases/mes-host-large-heap.scm" > "$work/small.out" 2> "$work/small.err" || status=$?
test "$status" = 1
grep -qx 'rsc: out of memory' "$work/small.err"
echo 'ok - Mes host ELF: 256 MiB/arena succeeds, 128 MiB/arena fails safely'
