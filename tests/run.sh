#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_QFITZAH" >&2
  exit 2
fi

qfitzah=$1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
case_dir="$repo_root/tests/cases"

run_case() {
  local name=$1
  local runner=$2
  local input=$case_dir/$name.qf1
  local expected=$case_dir/$name.expected
  local unexpected=$case_dir/$name.unexpected
  local hex=$case_dir/$name.hex
  local output
  local actual_hex
  local expected_hex
  local snippet

  output=$(mktemp)
  timeout 5s "$runner" < "$input" > "$output"

  if [[ -f "$expected" ]]; then
    while IFS= read -r snippet; do
      [[ -z "$snippet" ]] && continue
      if ! grep -aFq "$snippet" "$output"; then
        printf 'FAIL %s: expected to find %q in output:\n' "$name" "$snippet" >&2
        cat "$output" >&2
        rm -f "$output"
        exit 1
      fi
    done < "$expected"
  fi

  if [[ -f "$unexpected" ]]; then
    while IFS= read -r snippet; do
      [[ -z "$snippet" ]] && continue
      if grep -aFq "$snippet" "$output"; then
        printf 'FAIL %s: did not expect to find %q in output:\n' "$name" "$snippet" >&2
        cat "$output" >&2
        rm -f "$output"
        exit 1
      fi
    done < "$unexpected"
  fi

  if [[ -f "$hex" ]]; then
    actual_hex=$(od -An -tx1 -v "$output" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    expected_hex=$(tr -s '[:space:]' ' ' < "$hex" | sed 's/^ //; s/ $//')
    if [[ "$actual_hex" != "$expected_hex" ]]; then
      printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
      rm -f "$output"
      exit 1
    fi
  fi

  rm -f "$output"
  printf 'ok - %s\n' "$name"
}

run_standard_cases() {
  local runner=$1
  local structural_output

  run_case "basic-rewrite" "$runner"
  run_case "multi-line-pipe" "$runner"
  run_case "repeated-atom-variable" "$runner"
  run_case "repeated-list-variable" "$runner"

  structural_output=$(timeout 5s "$runner" < "$case_dir/repeated-list-variable.qf1")

  if [[ $(grep -Fc "(Yes)" <<<"$structural_output") -ne 1 ]]; then
    printf 'FAIL repeated-list-variable: expected exactly one success:\n%s\n' "$structural_output" >&2
    exit 1
  fi

  run_case "unmatched-template-variable" "$runner"
  run_case "empty-list-pattern" "$runner"
  run_case "reader-ergonomics" "$runner"
  run_case "byte-output" "$runner"
  run_case "arithmetic-compiler" "$runner"
  run_case "meta2-arithmetic" "$runner"
  run_case "lisp-reverse" "$runner"
  run_case "full-lisp" "$runner"
  run_case "self-hosting-compiler" "$runner"
}

run_stage1_bootstrap() {
  local tmp
  local stage1

  tmp=$(mktemp -d)
  stage1=$tmp/qfitzah

  timeout 20s "$qfitzah" < "$repo_root/bootstrap/qfitzah-stage1.qf1" > "$stage1"

  if ! cmp -s "$qfitzah" "$stage1"; then
    printf 'FAIL stage1-bootstrap: regenerated binary differs from %s\n' "$qfitzah" >&2
    cmp -l "$qfitzah" "$stage1" | head -20 >&2 || true
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$stage1"
  run_standard_cases "$stage1"

  rm -rf "$tmp"
  printf 'ok - stage1-bootstrap\n'
}

run_standard_cases "$qfitzah"
run_stage1_bootstrap
