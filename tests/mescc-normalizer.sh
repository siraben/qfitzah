#!/usr/bin/env bash
set -euo pipefail
if (( $# != 4 )); then
  echo "usage: $0 HOST MES_SOURCE GENERATED_NYACC NORMALIZER" >&2
  exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
nyacc=$(realpath "$3")
normalizer=$(realpath "$4")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-normalizer-test.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "normalizer artifacts: $work" >&2; fi' EXIT
"$normalizer" < "$root/tests/cases/mescc-normalize.scm" > "$work/native.scm"
env "%prefix=$mes" "$host" --mes "$mes" -L "$nyacc/module" \
  "$root/tests/probes/mescc-normalize-reference.scm" -- \
  "$root/tests/cases/mescc-normalize.scm" > "$work/reference.scm"
"$host" "$root/tests/compare-scheme-source.scm" -- "$work/reference.scm" "$work/native.scm"
args=("$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" -S --arch x86 -m32
      -o "$work/probe.M1" "$root/tests/cases/mescc-labels.c")
env -u QFITZAH_MESCC_NORMALIZER -u QFITZAH_MESCC_AST_OUTPUT bash "${args[@]}"
cp "$work/probe.M1" "$work/reference.M1"
QFITZAH_MESCC_NORMALIZER="$normalizer" QFITZAH_MESCC_AST_OUTPUT="$work/probe.E" \
  bash "${args[@]}"
cmp "$work/reference.M1" "$work/probe.M1"
grep -qx qfitzah-mescc-ast-v1 "$work/probe.E.complete"
QFITZAH_MESCC_RAW_AST_OUTPUT="$work/input.raw" \
  bash "$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" -S --arch x86 -m32 \
  -o "$work/unused.M1" "$root/tests/cases/mescc-labels.c"
grep -qx qfitzah-mescc-raw-ast-v1 "$work/input.raw.complete"
test ! -e "$work/unused.M1"
"$normalizer" < "$work/input.raw" > "$work/again.E"
"$host" "$root/tests/compare-scheme-source.scm" -- "$work/probe.E" "$work/again.E"
status=0
QFITZAH_MESCC_RAW_AST_OUTPUT="$work/input.raw" \
  bash "$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" -S \
  "$root/tests/cases/mescc-labels.c" > "$work/rejected" 2>&1 || status=$?
test "$status" = 1
grep -q 'raw AST destination already exists' "$work/rejected"
# Multiple source files use upstream compilation unchanged, never a partial AST.
multi=("$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" -S --arch x86 -m32
       -o "$work/multi.M1" "$root/tests/cases/mescc-typedef-library.c"
       "$root/tests/cases/mescc-typedef-main.c")
env -u QFITZAH_MESCC_NORMALIZER -u QFITZAH_MESCC_AST_OUTPUT bash "${multi[@]}"
cp "$work/multi.M1" "$work/multi-reference.M1"
QFITZAH_MESCC_NORMALIZER="$normalizer" bash "${multi[@]}"
cmp "$work/multi-reference.M1" "$work/multi.M1"
for input in '' '(trans-unit) (trans-unit)'; do
  status=0
  printf '%s\n' "$input" | "$normalizer" > "$work/bad" 2> "$work/bad.err" || status=$?
  test "$status" = 1
  test ! -s "$work/bad"
done
echo 'ok - native normalization equivalence, C-to-M1 equality and checkpoint/EOF guards'
