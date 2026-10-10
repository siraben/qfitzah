#!/usr/bin/env bash
# Tests real upstream IR -> M1 -> ELF, not the unfinished C frontend.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "usage: $0 MES_HOST M1_LINK MES_SOURCE" >&2; exit 2
fi
host=$(realpath "$1")
link=$(realpath "$2")
mes=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-mescc-backend.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "backend artifacts: $work" >&2; fi' EXIT
timeout 60s "$host" --mes "$mes" "$root/tests/cases/mescc-backend.scm" > "$work/backend.M1"
"$link" --architecture x86 --little-endian \
  -f "$mes/lib/x86-mes/x86.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-header.hex2" \
  -f "$root/tests/cases/mescc-backend-entry.M1" \
  -f "$work/backend.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-footer-single-main.hex2" -o "$work/backend"
chmod +x "$work/backend"
status=0
timeout 10s "$work/backend" || status=$?
test "$status" = 42
echo 'ok - MesCC IR instruction selection, global data, M1 emission and source-built ELF linking'
