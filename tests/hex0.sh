#!/usr/bin/env bash
# Fixtures/oracles only use the host shell; the assembler is source-built.
set -euo pipefail
if (( $# != 1 )); then echo "usage: $0 SOURCE_BUILT_HEX0" >&2; exit 2; fi
hex0=$(realpath "$1")
work=$(mktemp -d "${TMPDIR:-/tmp}/qfitzah-hex0-test.XXXXXX")
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "hex0 artifacts: $work" >&2; fi' EXIT
printf '00 7F 80 ff\nA; ignored 123\n B # ignored ff' > "$work/input"
printf '\x00\x7f\x80\xff\xab' > "$work/expected"
"$hex0" "$work/input" "$work/actual"
cmp "$work/expected" "$work/actual"
# Cover every byte, including NUL and non-ASCII bytes (never UTF-8 encode them).
: > "$work/input"
: > "$work/expected"
for (( i=0; i<256; i++ )); do
  printf '%02x\n' "$i" >> "$work/input"
  printf -v octal '%03o' "$i"
  printf '%b' "\\$octal" >> "$work/expected"
done
"$hex0" "$work/input" "$work/actual"
cmp "$work/expected" "$work/actual"
cp "$work/actual" "$work/preserved"
for bad in '0' 'G0' '00z' 'a; comment to EOF'; do
  printf '%s' "$bad" > "$work/input"
  status=0
  "$hex0" "$work/input" "$work/actual" > "$work/out" 2> "$work/err" || status=$?
  test "$status" = 1
  cmp "$work/preserved" "$work/actual"
done
printf '# empty\n; comment' > "$work/input"
"$hex0" "$work/input" "$work/actual"
test ! -s "$work/actual"
echo 'ok - hex0 byte range, comments, malformed input and output preservation'
