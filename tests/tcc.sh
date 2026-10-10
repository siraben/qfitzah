#!/usr/bin/env bash
# Only the explicitly supplied, source-bootstrapped TCC compiles these probes.
set -euo pipefail
if [[ $# -lt 1 ]]; then echo "usage: $0 BOOTSTRAPPED_TCC [FLAGS...]" >&2; exit 2; fi
cc=$(realpath "$1")
shift
flags=("$@")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/qfitzah-tcc-test.XXXXXX")
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "TCC artifacts: $work" >&2; fi' EXIT
"$cc" -dumpversion
for probe in probe numeric; do
  for round in a b; do
    timeout 30s "$cc" "${flags[@]}" -static -o "$work/$probe-$round" "$root/tests/cases/tcc-$probe.c"
    timeout 10s "$work/$probe-$round" "$work/io-$round" > "$work/actual"
    if [[ $probe == probe ]]; then
      printf 'tcc C probe passed\n' > "$work/expected"
    else
      printf 'tcc numeric probe passed\n' > "$work/expected"
    fi
    diff -u "$work/expected" "$work/actual"
  done
  cmp "$work/$probe-a" "$work/$probe-b"
done
printf 'int main( { this is not C; }\n' > "$work/invalid.c"
set +e
"$cc" "${flags[@]}" -static -o "$work/invalid" "$work/invalid.c" > "$work/error" 2>&1
status=$?
set -e
[[ $status == 1 ]] || { echo "invalid C returned $status, expected 1" >&2; exit 1; }
[[ ! -e "$work/invalid" ]] || { echo 'invalid C produced an output file' >&2; exit 1; }
# Duplicate strong symbols must fail before publishing an executable, too.
printf 'int clash=1; int main(void){return 0;}\n' > "$work/one.c"
printf 'int clash=2;\n' > "$work/two.c"
for unit in one two; do
  "$cc" "${flags[@]}" -c -o "$work/$unit.o" "$work/$unit.c"
done
status=0
"$cc" "${flags[@]}" -static -o "$work/duplicate" "$work/one.o" "$work/two.o" \
  > "$work/link-error" 2>&1 || status=$?
[[ $status == 1 && ! -e $work/duplicate ]] || {
  echo "duplicate symbols returned $status or published an output" >&2; exit 1;
}
echo 'ok - TCC C/ABI/library probes, repeated output, syntax and linker diagnostics'
