#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 5 ]]; then
  echo "usage: $0 MES_HOST M1_LINK MES_SOURCE GENERATED_NYACC BUILT_LIBC_MINI" >&2; exit 2
fi
host=$(realpath "$1")
link=$(realpath "$2")
mes=$(realpath "$3")
nyacc=$(realpath "$4")
libc=$(realpath "$5")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-libc-mini-test.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "libc artifacts: $work" >&2; fi' EXIT
bash "$root/bootstrap/mescc.sh" "$host" "$libc/source" "$nyacc" \
  -S --arch x86 -m32 -DHAVE_CONFIG_H=1 \
  -o "$work/probe.M1" "$root/tests/cases/mescc-libc.c"
"$link" --architecture x86 --little-endian \
  -f "$mes/lib/x86-mes/x86.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-header.hex2" \
  -f "$libc/libc-mini.M1" -f "$work/probe.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-footer-single-main.hex2" -o "$work/probe"
chmod +x "$work/probe"
status=0
QFITZAH_LIBC_PROBE=yes timeout 10s "$work/probe" xyz > "$work/actual" || status=$?
test "$status" = 42
printf 'Mes libc from C source\n' > "$work/expected"
diff -u "$work/expected" "$work/actual"
echo 'ok - C-built Mes crt1/libc-mini: argc, argv, envp, strlen and puts'
