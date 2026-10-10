#!/usr/bin/env bash
# Optional third argument exercises the pinned upstream definitions and headers.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 SEED RSC_COMPILER [MES_SOURCE]" >&2; exit 2
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-m1-test.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "M1 artifacts: $work" >&2; fi' EXIT
bash "$root/bootstrap/build-m1.sh" "$1" "$2" "$work/build"
tool="$work/build/m1-link"
"$tool" --base-address 0 "$root/tests/cases/m1-layout.M1" -o "$work/layout"
od -An -v -tx1 "$work/layout" | tr -d '[:space:]' > "$work/actual"
tr -d '[:space:]' < "$root/tests/cases/m1-layout.expected" > "$work/expected"
cmp "$work/expected" "$work/actual"
printf '!1 < !2\n' > "$work/align.M1"
"$tool" --base-address 0 "$work/align.M1" > "$work/align"
printf '\x01\x00\x00\x00\x02' > "$work/expected"
cmp "$work/expected" "$work/align"
"$tool" --base-address 1 "$work/align.M1" > "$work/align"
printf '\x01\x00\x00\x02' > "$work/expected"
cmp "$work/expected" "$work/align"
expect_exit42() {
  chmod +x "$1"
  local status=0
  timeout 10s "$1" || status=$?
  test "$status" = 42
}
"$tool" --architecture x86 --little-endian \
  -f "$root/tests/cases/m1-x86.M1" -f "$root/tests/cases/m1-elf-header.M1" \
  -f "$root/tests/cases/m1-exit.M1" -o "$work/exit42"
expect_exit42 "$work/exit42"
reject() {
  local source=$1 message=$2 status=0
  printf '%s\n' "$source" > "$work/reject.M1"
  printf 'preserved' > "$work/protected"
  timeout 10s "$tool" --base-address 0 "$work/reject.M1" -o "$work/protected" \
    > "$work/stdout" 2> "$work/stderr" || status=$?
  test "$status" = 1
  grep -F "$message" "$work/stderr" > /dev/null
  test ! -s "$work/stdout"
  test "$(< "$work/protected")" = preserved
}
reject '%missing' 'undefined label'
reject ':a 00 :a' 'duplicate definition'
reject 'DEFINE A B DEFINE B A A' 'recursive macro'
reject 'DEFINE A' 'incomplete DEFINE'
reject '0' 'odd hexadecimal digit count'
reject 'zz' 'invalid hexadecimal bytes'
reject '"unclosed' 'unterminated quote'
reject ':' 'empty label'
reject '%' 'empty reference'
reject "$(printf '!far\n'; printf '00 %.0s' {1..128}; printf '\n:far\n')" 'relocation out of range'
if [[ $# == 3 ]]; then
  mes=$(realpath "$3")
  "$tool" -f "$mes/lib/x86-mes/x86.M1" \
    -f "$mes/lib/linux/x86-mes/elf32-0header.hex2" -f "$root/tests/cases/m1-exit.M1" -o "$work/upstream-m1"
  expect_exit42 "$work/upstream-m1"
  "$tool" -f "$mes/lib/linux/x86-mes/elf32-0header.hex2" \
    -f "$mes/lib/linux/x86-mes/elf32-0exit-42.hex2" -o "$work/upstream-hex2"
  test "$(wc -c < "$work/upstream-hex2")" = 112
  expect_exit42 "$work/upstream-hex2"
  "$tool" -f "$mes/lib/linux/x86-mes/elf32-0header.hex2" \
    -f "$mes/lib/linux/x86-mes/elf32-0hello-mes.hex2" -o "$work/upstream-hello"
  chmod +x "$work/upstream-hello"
  # This upstream fixture explicitly writes descriptor zero, not stdout.
  timeout 10s "$work/upstream-hello" 0> "$work/hello"
  printf 'Hello, GNU Mes!\n' > "$work/expected"
  cmp "$work/expected" "$work/hello"
fi
echo 'ok - source-built M1/hex2 layout, relocations, execution and rejection tests'
