#!/usr/bin/env bash
# A shared function-pointer typedef is metadata, not a common data definition.
set -euo pipefail
if (( $# != 4 )); then
  echo "usage: $0 HOST M1_LINK MES_SOURCE GENERATED_NYACC" >&2
  exit 2
fi
host=$(realpath "$1")
link=$(realpath "$2")
mes=$(realpath "$3")
nyacc=$(realpath "$4")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-mescc-units.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "multi-unit artifacts: $work" >&2; fi' EXIT
for unit in library main; do
  timeout 300s bash "$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" \
    -S --arch x86 -m32 -I "$root/tests/cases" \
    -o "$work/$unit.M1" "$root/tests/cases/mescc-typedef-$unit.c"
  test -s "$work/$unit.M1"
  if grep -qx ':transform_fn' "$work/$unit.M1"; then
    echo 'typedef incorrectly emitted as an object' >&2
    exit 1
  fi
done
grep -qx ':saved' "$work/main.M1"
"$link" --architecture x86 --little-endian \
  -f "$mes/lib/x86-mes/x86.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-header.hex2" \
  -f "$root/tests/cases/mescc-backend-entry.M1" \
  -f "$work/library.M1" -f "$work/main.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-footer-single-main.hex2" -o "$work/probe"
chmod +x "$work/probe"
status=0
timeout 10s "$work/probe" || status=$?
test "$status" = 42
echo 'ok - MesCC shared typedef, pointer storage and indirect calls across two C units'
