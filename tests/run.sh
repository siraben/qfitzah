#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_QFITZAH" >&2
  exit 2
fi

qfitzah=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

run_case() {
  local name=$1
  local input=$2
  local expected=$3
  local unexpected=${4-}
  local output

  output=$(timeout 5s "$qfitzah" <<<"$input")

  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'FAIL %s: expected to find %q in output:\n%s\n' "$name" "$expected" "$output" >&2
    exit 1
  fi

  if [[ -n "$unexpected" ]] && grep -Fq "$unexpected" <<<"$output"; then
    printf 'FAIL %s: did not expect to find %q in output:\n%s\n' "$name" "$unexpected" "$output" >&2
    exit 1
  fi

  printf 'ok - %s\n' "$name"
}

run_case \
  "single rewrite" \
  $'(Id x) x\n(Id 3)\n' \
  "3"

run_case \
  "multi-line pipe input is not dropped" \
  $'(Eq x x) (Yes x)\n(Eq 3 3)\n' \
  "(Yes 3)"

run_case \
  "repeated atom variables must match" \
  $'(Eq x x) (Yes x)\n(Eq 3 4)\n' \
  "(Eq 3 4)" \
  "(Yes 4)"

run_case \
  "unmatched template variables are preserved" \
  $'(Do Nothing) no\n(Do Nothing)\n' \
  "no"

run_case \
  "empty list pattern matches only empty list" \
  $'(Gallygoogle ()) (Bad)\n(Gallygoogle Foo)\n' \
  "(Gallygoogle Foo)" \
  "(Bad)"

example_output=$(timeout 5s "$qfitzah" < "$repo_root/examples/arithmetic-compiler.qf1")
example_expected="(Push 2 (Push 3 (Push 4 (Mul (Add Done)))))"

if ! grep -Fq "$example_expected" <<<"$example_output"; then
  printf 'FAIL arithmetic compiler example: expected to find %q in output:\n%s\n' "$example_expected" "$example_output" >&2
  exit 1
fi

printf 'ok - arithmetic compiler example\n'
