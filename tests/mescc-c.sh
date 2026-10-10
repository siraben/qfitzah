#!/usr/bin/env bash
# Actual C -> Nyacc -> MesCC -> M1 -> ELF, without a host compiler/linker.
set -euo pipefail
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 MES_HOST M1_LINK MES_SOURCE GENERATED_NYACC [exit|control|strings|large-global|labels]" >&2; exit 2
fi
case ${5:-all} in
  all) probes=(exit control strings large-global labels);;
  exit|control|strings|large-global|labels) probes=("$5");;
  *) echo "unknown C probe: $5" >&2; exit 2;;
esac
host=$(realpath "$1")
link=$(realpath "$2")
mes=$(realpath "$3")
nyacc=$(realpath "$4")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-mescc-c.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "C artifacts: $work" >&2; fi' EXIT
# Even a mixed mode containing -S must not enter another upstream backend.
status=0
bash "$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" \
  -E -S "$root/tests/cases/mescc-exit.c" > "$work/rejected" 2>&1 || status=$?
test "$status" = 1
grep -q 'only compilation to M1 is enabled' "$work/rejected"
for probe in "${probes[@]}"; do
  timeout 300s bash "$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" \
    -S --arch x86 -m32 -DEXPECTED=42 \
    -o "$work/$probe.M1" "$root/tests/cases/mescc-$probe.c"
  test -s "$work/$probe.M1"
  "$link" --architecture x86 --little-endian \
    -f "$mes/lib/x86-mes/x86.M1" \
    -f "$mes/lib/linux/x86-mes/elf32-header.hex2" \
    -f "$root/tests/cases/mescc-backend-entry.M1" \
    -f "$work/$probe.M1" \
    -f "$mes/lib/linux/x86-mes/elf32-footer-single-main.hex2" -o "$work/$probe"
  chmod +x "$work/$probe"
  status=0
  timeout 10s "$work/$probe" || status=$?
  test "$status" = 42
  echo "ok - MesCC C $probe through source-built ELF linking"
done
if [[ ${5:-all} == all ]]; then
  bash "$root/tests/mescc-units.sh" "$host" "$link" "$mes" "$nyacc"
fi
