#!/usr/bin/env bash
# Comparison is post-generation validation, never input to generation/evaluation.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo "usage: $0 MES_HOST MES_SOURCE ORIGINAL_NYACC GENERATED_NYACC" >&2; exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
original=$(realpath "$3")
generated=$(realpath "$4")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for grammar in cpp c99 c99x c99cx; do
  for kind in act tab; do
    file="module/nyacc/lang/c99/mach.d/$grammar-$kind.scm"
    test -s "$generated/$file"
    "$host" --mes "$mes" "$root/tests/compare-scheme-source.scm" -- "$original/$file" "$generated/$file"
    echo "ok - regenerated $grammar-$kind source datums"
  done
done
actual=$(mktemp)
trap 'rm -f "$actual"' EXIT
for parser in cpp c99 c99cx pprint; do
  "$host" --mes "$mes" -L "$generated/module" "$root/tests/cases/nyacc-$parser.scm" > "$actual"
  diff -u "$root/tests/cases/nyacc-$parser.expected" "$actual"
  echo "ok - Nyacc $parser execution"
done
