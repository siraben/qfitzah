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

run_qfasm2_exit42() {
  local tmp
  local actual_hex
  local expected_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" "$repo_root/bootstrap/exit42.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/exit42"

  actual_hex=$(od -An -tx1 -v "$tmp/exit42" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/qfasm2-exit42.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL qfasm2-exit42: expected hex:\n%s\nactual hex:\n%s\n' "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/exit42"
  set +e
  "$tmp/exit42"
  status=$?
  set -e

  if [[ $status -ne 42 ]]; then
    printf 'FAIL qfasm2-exit42: expected exit status 42, got %s\n' "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - qfasm2-exit42\n'
}

run_qfasm2_exit42

run_qfasm3_exit42() {
  local tmp
  local actual_hex
  local expected_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/stage3-exit42.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/exit42"

  actual_hex=$(od -An -tx1 -v "$tmp/exit42" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/qfasm3-exit42.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL qfasm3-exit42: expected hex:\n%s\nactual hex:\n%s\n' "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/exit42"
  set +e
  "$tmp/exit42"
  status=$?
  set -e

  if [[ $status -ne 42 ]]; then
    printf 'FAIL qfasm3-exit42: expected exit status 42, got %s\n' "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - qfasm3-exit42\n'
}

run_qfasm3_exit42

run_qfc4_binary() {
  local name=$1
  local expected_status=$2
  local expected_runtime_hex=${3:-}
  local tmp
  local actual_hex
  local expected_hex
  local runtime_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name" > "$tmp/runtime.out"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  if [[ -n "$expected_runtime_hex" ]]; then
    runtime_hex=$(od -An -tx1 -v "$tmp/runtime.out" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    if [[ "$runtime_hex" != "$expected_runtime_hex" ]]; then
      printf 'FAIL %s: expected runtime stdout hex %s, got %s\n' "$name" "$expected_runtime_hex" "$runtime_hex" >&2
      rm -rf "$tmp"
      exit 1
    fi
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_binary "stage4-exit42" 42
run_qfc4_binary "stage4-tagged-exit43" 43
run_qfc4_binary "stage4-nybble" 10
run_qfc4_binary "stage4-emit-byte" 0 "41"
run_qfc4_binary "stage4-emit-bytes" 0 "41 42 43 44 45"
run_qfc4_binary "stage4-emit-bytes-object" 0 "41"
run_qfc4_binary "stage4-emit-bytes-nested" 0 "41"
run_qfc4_binary "stage4-emit-bytes-general" 0 "41"
run_qfc4_binary "stage4-is-bytes-content" 42
run_qfc4_binary "stage4-is-bytes-content-reject" 1
run_qfc4_binary "stage4-is-bytes-content-output" 0 "41"
run_qfc4_binary "stage4-is-bytes-content-linear" 0 "41"
