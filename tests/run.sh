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
  local input=$case_dir/$name.qf1
  local expected=$case_dir/$name.expected
  local unexpected=$case_dir/$name.unexpected
  local hex=$case_dir/$name.hex
  local output
  local actual_hex
  local expected_hex
  local snippet

  output=$(mktemp)
  timeout 5s "$qfitzah" < "$input" > "$output"

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

run_case "basic-rewrite"
run_case "multi-line-pipe"
run_case "multiline-forms"
multiline_eof_output=$(mktemp)
printf '%s' "$(cat "$case_dir/multiline-eof.qf1")" \
  | timeout 5s "$qfitzah" > "$multiline_eof_output"
if ! grep -aFq "$(cat "$case_dir/multiline-eof.expected")" "$multiline_eof_output"; then
  printf 'FAIL multiline-eof: expected final logical record at EOF:\n' >&2
  cat "$multiline_eof_output" >&2
  rm -f "$multiline_eof_output"
  exit 1
fi
rm -f "$multiline_eof_output"
printf 'ok - multiline-eof\n'
run_case "repeated-atom-variable"
run_case "repeated-list-variable"

structural_output=$(timeout 5s "$qfitzah" < "$case_dir/repeated-list-variable.qf1")

if [[ $(grep -Fc "(Yes)" <<<"$structural_output") -ne 1 ]]; then
  printf 'FAIL repeated-list-variable: expected exactly one success:\n%s\n' "$structural_output" >&2
  exit 1
fi

run_case "unmatched-template-variable"
run_case "empty-list-pattern"
run_case "reader-ergonomics"
run_case "byte-flatten"
run_case "byte-output"
run_case "arithmetic-compiler"
run_case "meta2-arithmetic"
run_case "lisp-reverse"
run_case "full-lisp"
run_case "self-hosting-compiler"

run_bootstrap_stage1_multiline_rules() {
  local output
  local snippet

  output=$(mktemp)
  timeout 5s "$qfitzah" < "$repo_root/bootstrap/stage1-multiline-rules.qf1" > "$output"

  while IFS= read -r snippet; do
    [[ -z "$snippet" ]] && continue
    if ! grep -aFq "$snippet" "$output"; then
      printf 'FAIL stage1-multiline-rules: expected to find %q in output:\n' "$snippet" >&2
      cat "$output" >&2
      rm -f "$output"
      exit 1
    fi
  done < "$case_dir/stage1-multiline-rules.expected"

  rm -f "$output"
  printf 'ok - stage1-multiline-rules\n'
}

run_bootstrap_stage1_multiline_rules

## Stage 1: the general assembler. Each case assembles under the seed with
## bootstrap/qfasm.qf1, byte-compares the produced ELF against the expected
## hex from the independent Python model (tools/generate_qfasm_tests.py),
## then runs the binary and checks its exit status.

qfasm=$repo_root/bootstrap/qfasm.qf1

run_qfasm_case() {
  local name=$1
  local tmp elf actual_hex expected_hex status expected_status

  tmp=$(mktemp -d)
  elf=$tmp/$name.elf
  cat "$qfasm" "$case_dir/$name.qfasm" | timeout 120s "$qfitzah" > "$elf"

  actual_hex=$(od -An -tx1 -v "$elf" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: assembled ELF differs from the Python model\n' "$name" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$elf"
  set +e
  timeout 5s "$elf"
  status=$?
  set -e
  expected_status=$(cat "$case_dir/$name.status")
  if [[ "$status" -ne "$expected_status" ]]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfasm_arith() {
  local actual
  actual=$(mktemp)
  cat "$qfasm" "$case_dir/qfasm-arith.qfasm" | timeout 60s "$qfitzah" > "$actual"
  if ! diff -u "$case_dir/qfasm-arith.out" "$actual" >&2; then
    printf 'FAIL qfasm-arith: 32-bit arithmetic differs from the Python model\n' >&2
    rm -f "$actual"
    exit 1
  fi
  rm -f "$actual"
  printf 'ok - qfasm-arith\n'
}

run_qfasm_arith
run_qfasm_case "qfasm-exit42"
run_qfasm_case "qfasm-big"

## Stage 2: the scheme0 interpreter. Assemble it under the seed, then run
## the Scheme corpus and require exact output.

scheme0_dir=$(mktemp -d)
scheme0_elf=$scheme0_dir/scheme0.elf
cat "$repo_root/bootstrap/qfasm.qf1" "$repo_root/bootstrap/scheme0.qfasm" \
  | timeout 120s "$qfitzah" > "$scheme0_elf"
chmod +x "$scheme0_elf"

run_scheme0_corpus() {
  local tmp elf actual
  tmp=$(mktemp -d)
  elf=$scheme0_elf
  actual=$tmp/corpus.out
  set +e
  timeout 30s "$elf" < "$case_dir/scheme0-corpus.scm" > "$actual"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf 'FAIL scheme0-corpus: interpreter exited %s\n' "$status" >&2
    cat "$actual" >&2
    rm -rf "$tmp"
    exit 1
  fi
  if ! diff -u "$case_dir/scheme0-corpus.out" "$actual" >&2; then
    printf 'FAIL scheme0-corpus: output differs\n' >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$tmp"
  printf 'ok - scheme0-corpus\n'
}

run_scheme0_corpus

## Stage 3 (in progress): the sc1 reader, Scheme running on scheme0.
run_sc1_reader() {
  local actual
  actual=$(mktemp)
  cat "$repo_root/bootstrap/sc1-reader.scm" "$case_dir/sc1-reader-echo.scm" \
      "$case_dir/sc1-reader-input.scm" \
    | timeout 30s "$scheme0_elf" > "$actual"
  if ! diff -u "$case_dir/sc1-reader.out" "$actual" >&2; then
    printf 'FAIL sc1-reader: output differs\n' >&2
    rm -f "$actual"
    exit 1
  fi
  rm -f "$actual"
  printf 'ok - sc1-reader\n'
}

run_sc1_reader
rm -rf "$scheme0_dir"

printf 'all tests passed\n'
