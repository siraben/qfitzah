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

run_qfasm2_exit42_n221() {
  local tmp
  local actual_size
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm-n221-ext.qf1" \
      "$repo_root/bootstrap/qfasm2-exit42-n221.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/exit42-n221"

  actual_size=$(wc -c < "$tmp/exit42-n221")
  if [[ $actual_size -ne 305 ]]; then
    printf 'FAIL qfasm2-exit42-n221: expected 305-byte ELF, got %s bytes\n' "$actual_size" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/exit42-n221"
  set +e
  "$tmp/exit42-n221"
  status=$?
  set -e

  if [[ $status -ne 42 ]]; then
    printf 'FAIL qfasm2-exit42-n221: expected exit status 42, got %s\n' "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - qfasm2-exit42-n221\n'
}

run_qfasm2_exit42_n221

run_qfasm2_entry_n221() {
  local tmp
  local actual_size
  local entry_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm-n221-ext.qf1" \
      "$repo_root/bootstrap/qfasm2-entry-n221.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/entry-n221"

  actual_size=$(wc -c < "$tmp/entry-n221")
  if [[ $actual_size -ne 317 ]]; then
    printf 'FAIL qfasm2-entry-n221: expected 317-byte ELF, got %s bytes\n' "$actual_size" >&2
    rm -rf "$tmp"
    exit 1
  fi

  entry_hex=$(od -An -j24 -N4 -tx1 -v "$tmp/entry-n221" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$entry_hex" != "31 81 04 08" ]]; then
    printf 'FAIL qfasm2-entry-n221: expected entry 31 81 04 08, got %s\n' "$entry_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/entry-n221"
  set +e
  "$tmp/entry-n221"
  status=$?
  set -e

  if [[ $status -ne 42 ]]; then
    printf 'FAIL qfasm2-entry-n221: expected exit status 42, got %s\n' "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - qfasm2-entry-n221\n'
}

run_qfasm2_entry_n221

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
  local qfc4_exts=()
  local tmp
  local actual_hex
  local expected_hex
  local runtime_hex
  local status

  if [[ $# -gt 3 ]]; then
    shift 3
    qfc4_exts=("$@")
  fi

  tmp=$(mktemp -d)
  {
    cat "$repo_root/bootstrap/qfasm2.qf1" \
        "$repo_root/bootstrap/qfasm3.qf1" \
        "$repo_root/bootstrap/qfc4.qf1"
    for qfc4_ext in "${qfc4_exts[@]}"; do
      cat "$repo_root/bootstrap/$qfc4_ext"
    done
    cat "$repo_root/bootstrap/$name.qf1"
  } | timeout 5s "$qfitzah" > "$tmp/$name"

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
run_qfc4_binary "stage5-optimization-qfc4" 42 "" "qfc4-opt-ext.qf1"
run_qfc4_binary "stage5-known-match-opt-qfc4" 42 "" "qfc4-opt-ext.qf1"
run_qfc4_binary "stage5-tco-qfc4" 42 "" "qfc4-opt-ext.qf1"
run_qfc4_binary "stage4-tagged-exit43" 43
run_qfc4_binary "stage4-nybble" 10
run_qfc4_binary "stage4-emit-byte" 0 "41"
run_qfc4_binary "stage4-emit-bytes" 0 "41 42 43 44 45"
run_qfc4_binary "stage4-emit-bytes-object" 0 "41"
run_qfc4_binary "stage4-emit-bytes-nested" 0 "41"
run_qfc4_binary "stage4-emit-bytes-general" 0 "41"
run_qfc4_binary "stage5-print-list-qfc4" 0 "28 61 29"
run_qfc4_binary "stage5-print-empty-list-qfc4" 0 "28 29" "qfc4-print-nil-ext.qf1"
run_qfc4_binary "stage5-print-nil-and-atom-qfc4" 0 "28 29 61" "qfc4-print-nil-ext.qf1"
run_qfc4_binary "stage5-print-list-tail-qfc4" 0 "28 61 20 62 29" "qfasm-n224-ext.qf1"
run_qfc4_binary "stage5-print-nested-list-qfc4" 0 "28 61 20 28 62 29 29" "qfasm-n224-ext.qf1" "qfasm-n232-size-ext.qf1"
run_qfc4_binary "stage4-is-bytes-content" 42
run_qfc4_binary "stage4-is-bytes-content-reject" 1
run_qfc4_binary "stage4-is-bytes-content-output" 0 "41"
run_qfc4_binary "stage4-is-bytes-content-linear" 0 "41"

run_qfc4_dispatch_binary() {
  local name=$1
  local expected_status=$2
  local qfc4_ext=${3:-qfc4-dispatch-ext.qf1}
  local tmp
  local actual_hex
  local expected_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-dispatch-ext.qf1" \
      "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/$qfc4_ext" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 20s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_dispatch_binary "stage5-dispatch-table-qfc4" 42
run_qfc4_dispatch_binary "stage5-dispatch-chain-qfc4" 42 "qfc4-dispatch-chain-ext.qf1"

run_qfc4_byte_output_binary() {
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
      "$repo_root/bootstrap/qfasm-byte-output-ext.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfc4-byte-output.qf1" \
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

run_qfc4_byte_output_binary "stage4-is-bytes-content-linear-direct" 0 "41"

run_qfc4_heap_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_binary "stage5-pair-allocation" 42
run_qfc4_heap_binary "stage5-bump-alloc" 19
run_qfc4_heap_binary "stage5-alloc-proc" 19

run_qfc4_heap_raw_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-raw-data-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_raw_binary "stage5-copy-root-gc-qfc4" 19

run_qfc4_heap_copy_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-copy-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_copy_binary "stage5-copy-graph-gc-qfc4" 19

run_qfc4_heap_list_staged_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-list-copy-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name.m3"

  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
      "$tmp/$name.m3" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_list_staged_binary "stage5-copy-list-gc-qfc4" 19

run_qfc4_heap_object_staged_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-copy-ext.qf1" \
      "$repo_root/bootstrap/qfc4-object-copy-ext.qf1" \
      "$repo_root/bootstrap/qfc4-object-data-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name.m3"

  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
      "$tmp/$name.m3" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_object_staged_binary "stage5-copy-two-field-object-gc-qfc4" 23

run_qfc4_heap_scan_staged_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-copy-ext.qf1" \
      "$repo_root/bootstrap/qfc4-object-data-ext.qf1" \
      "$repo_root/bootstrap/qfc4-scan-copy-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 10s "$qfitzah" > "$tmp/$name.m3"

  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-scan-ext.qf1" \
      "$tmp/$name.m3" \
    | timeout 10s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_scan_staged_binary "stage5-copy-tree-gc-qfc4" 35

run_qfc4_heap_forwarding_staged_binary() {
  local name=$1
  local expected_status=$2
  local qfc4_ext=$3
  local qfasm_ext=$4
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-object-data-ext.qf1" \
      "$repo_root/bootstrap/$qfc4_ext" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 10s "$qfitzah" > "$tmp/$name.m3"

  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-scan-ext.qf1" \
      "$repo_root/bootstrap/$qfasm_ext" \
      "$tmp/$name.m3" \
    | timeout 10s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_forwarding_staged_binary \
  "stage5-forwarding-gc-qfc4" 19 \
  "qfc4-forwarding-ext.qf1" \
  "qfasm-stage5-forwarding-ext.qf1"
run_qfc4_heap_forwarding_staged_binary \
  "stage5-forwarding-cycle-gc-qfc4" 23 \
  "qfc4-cycle-forwarding-ext.qf1" \
  "qfasm-stage5-cycle-forwarding-ext.qf1"

run_qfc4_heap_scan_forwarding_staged_binary() {
  local name=$1
  local expected_status=$2
  local qfc4_ext=${3:-qfc4-scan-forwarding-ext.qf1}
  local qfasm_ext=${4:-}
  local expected_runtime_hex=${5:-}
  local assemble_timeout=${6:-90}
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local runtime_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/qfc4-object-data-ext.qf1" \
      "$repo_root/bootstrap/qfc4-scan-copy-ext.qf1" \
      "$repo_root/bootstrap/$qfc4_ext" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 20s "$qfitzah" > "$tmp/$name.m3"

  if [[ -n "$qfasm_ext" ]]; then
    cat "$repo_root/bootstrap/qfasm2.qf1" \
        "$repo_root/bootstrap/qfasm3.qf1" \
        "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-scan-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-wide-branch-ext.qf1" \
        "$repo_root/bootstrap/$qfasm_ext" \
        "$tmp/$name.m3" \
      | timeout "${assemble_timeout}s" "$qfitzah" > "$tmp/$name"
  else
    cat "$repo_root/bootstrap/qfasm2.qf1" \
        "$repo_root/bootstrap/qfasm3.qf1" \
        "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-scan-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-wide-branch-ext.qf1" \
        "$tmp/$name.m3" \
      | timeout "${assemble_timeout}s" "$qfitzah" > "$tmp/$name"
  fi

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
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

run_qfc4_heap_scan_forwarding_staged_binary "stage5-scan-forwarding-gc-qfc4" 19
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-scan-forwarding-complex-gc-qfc4" 19 \
  "qfc4-scan-forwarding-complex-ext.qf1" \
  "qfasm-const-compare-ext.qf1"
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-scan-forwarding-dynamic-atom-gc-qfc4" 0 \
  "qfc4-scan-forwarding-dynamic-atom-ext.qf1" \
  "qfasm-stage5-branch-ext.qf1"
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-checked-scan-forwarding-dynamic-atom-gc-qfc4" 0 \
  "qfc4-checked-scan-forwarding-dynamic-atom-ext.qf1" \
  "qfasm-stage5-checked-ext.qf1" \
  "" \
  300
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-copy-bytes-output-gc-qfc4" 0 \
  "qfc4-copy-bytes-output-ext.qf1" \
  "" \
  "41"
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-copy-bytes-isbytes-output-gc-qfc4" 0 \
  "qfc4-copy-bytes-isbytes-output-ext.qf1" \
  "qfasm-byte-output-ext.qf1" \
  "41"
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-copy-nested-bytes-output-gc-qfc4" 0 \
  "qfc4-copy-nested-bytes-output-ext.qf1" \
  "qfasm-byte-output-ext.qf1" \
  "41"
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-copy-dynamic-atom-fields-gc-qfc4" 0 \
  "qfc4-copy-dynamic-atom-fields-ext.qf1" \
  "qfasm-stage5-branch-ext.qf1" \
  "41" \
  300
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-copy-dynamic-atom-nested-gc-qfc4" 0 \
  "qfc4-copy-dynamic-atom-nested-ext.qf1" \
  "qfasm-stage5-branch-ext.qf1" \
  "" \
  300
run_qfc4_heap_scan_forwarding_staged_binary \
  "stage5-copy-dynamic-atom-deep-gc-qfc4" 0 \
  "qfc4-copy-dynamic-atom-deep-ext.qf1" \
  "qfasm-stage5-branch-ext.qf1" \
  "" \
  300

run_qfc4_heap_check_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm3.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-heap-check-ext.qf1" \
      "$repo_root/bootstrap/qfc4.qf1" \
      "$repo_root/bootstrap/qfc4-heap-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfc4_heap_check_binary "stage5-alloc-checked-qfc4" 19
run_qfc4_heap_check_binary "stage5-alloc-overflow-qfc4" 7
run_qfc4_heap_check_binary "stage5-alloc-reset-gc-qfc4" 19

run_qfasm2_heap_check_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-heap-check-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfasm2_heap_check_binary "stage5-alloc-checked" 19
run_qfasm2_heap_check_binary "stage5-alloc-overflow" 7
run_qfasm2_heap_check_binary "stage5-alloc-reset-gc" 19
run_qfasm2_heap_check_binary "stage5-copy-root-gc" 19
run_qfasm2_heap_check_binary "stage5-copy-graph-gc" 19

run_qfasm2_stage5_list_binary() {
  local name=$1
  local expected_status=$2
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local status

  tmp=$(mktemp -d)
  cat "$repo_root/bootstrap/qfasm2.qf1" \
      "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
      "$repo_root/bootstrap/qfasm-heap-check-ext.qf1" \
      "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
      "$repo_root/bootstrap/$name.qf1" \
    | timeout 5s "$qfitzah" > "$tmp/$name"

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  chmod +x "$tmp/$name"
  set +e
  "$tmp/$name"
  status=$?
  set -e

  if [[ $status -ne $expected_status ]]; then
    printf 'FAIL %s: expected exit status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    rm -rf "$tmp"
    exit 1
  fi

  rm -rf "$tmp"
  printf 'ok - %s\n' "$name"
}

run_qfasm2_stage5_list_binary "stage5-copy-list-gc" 19
run_qfasm2_stage5_list_binary "stage5-copy-nested-pair-gc" 19
run_qfasm2_stage5_list_binary "stage5-copy-two-field-object-gc" 23

run_qfasm2_stage5_scan_binary() {
  local name=$1
  local expected_status=$2
  local extra_ext=${3:-}
  local assemble_timeout=${4:-20}
  local expected_runtime_hex=${5:-}
  local tmp
  local actual_hex
  local expected_hex
  local flags_hex
  local runtime_hex
  local status

  tmp=$(mktemp -d)
  if [[ -n "$extra_ext" ]]; then
    cat "$repo_root/bootstrap/qfasm2.qf1" \
        "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
        "$repo_root/bootstrap/qfasm-heap-check-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-scan-ext.qf1" \
        "$repo_root/bootstrap/$extra_ext" \
        "$repo_root/bootstrap/$name.qf1" \
      | timeout "${assemble_timeout}s" "$qfitzah" > "$tmp/$name"
  else
    cat "$repo_root/bootstrap/qfasm2.qf1" \
        "$repo_root/bootstrap/qfasm-heap-ext.qf1" \
        "$repo_root/bootstrap/qfasm-heap-check-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-list-ext.qf1" \
        "$repo_root/bootstrap/qfasm-stage5-scan-ext.qf1" \
        "$repo_root/bootstrap/$name.qf1" \
      | timeout "${assemble_timeout}s" "$qfitzah" > "$tmp/$name"
  fi

  actual_hex=$(od -An -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  expected_hex=$(tr -s '[:space:]' ' ' < "$case_dir/$name.hex" | sed 's/^ //; s/ $//')
  if [[ "$actual_hex" != "$expected_hex" ]]; then
    printf 'FAIL %s: expected hex:\n%s\nactual hex:\n%s\n' "$name" "$expected_hex" "$actual_hex" >&2
    rm -rf "$tmp"
    exit 1
  fi

  flags_hex=$(od -An -j76 -N1 -tx1 -v "$tmp/$name" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [[ "$flags_hex" != "07" ]]; then
    printf 'FAIL %s: expected writable executable segment flag 07, got %s\n' "$name" "$flags_hex" >&2
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

run_qfasm2_stage5_scan_binary "stage5-copy-tree-gc" 35
run_qfasm2_stage5_scan_binary "stage5-forwarding-gc" 19
run_qfasm2_stage5_scan_binary "stage5-forwarding-cycle-gc" 23
run_qfasm2_stage5_scan_binary "stage5-scan-forwarding-gc" 19 "qfasm-stage5-wide-branch-ext.qf1"
run_qfasm2_stage5_scan_binary "stage5-scan-forwarding-complex-gc" 19 "qfasm-stage5-wide-branch-ext.qf1" 60
run_qfasm2_stage5_scan_binary "stage5-scan-forwarding-dynamic-atom-gc" 0 "qfasm-stage5-wide-branch-ext.qf1" 60
run_qfasm2_stage5_scan_binary "stage5-checked-scan-forwarding-dynamic-atom-gc" 0 "qfasm-stage5-wide-branch-ext.qf1" 90
run_qfasm2_stage5_scan_binary "stage5-copy-bytes-output-gc" 0 "" 30 "41"
run_qfasm2_stage5_scan_binary "stage5-copy-bytes-isbytes-output-gc" 0 "qfasm-byte-output-ext.qf1" 45 "41"
run_qfasm2_stage5_scan_binary "stage5-copy-nested-bytes-output-gc" 0 "qfasm-byte-output-ext.qf1" 60 "41"
run_qfasm2_stage5_scan_binary "stage5-copy-dynamic-atoms-output-gc" 0 "qfasm-byte-output-ext.qf1" 180 "41"
run_qfasm2_stage5_scan_binary "stage5-copy-dynamic-atom-cdr-gc" 0 "" 180 "41"
run_qfasm2_stage5_scan_binary "stage5-copy-dynamic-atom-fields-gc" 0 "" 180 "41"
