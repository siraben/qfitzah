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
run_case "dotted-lists"
run_case "dotted-bytes"
run_case "byte-flatten"
run_case "byte-output"
run_case "arithmetic-compiler"
run_case "meta2-arithmetic"
run_case "lisp-reverse"
run_case "full-lisp"
run_case "self-hosting-compiler"

run_rule_directive() {
  local output
  local snippet

  output=$(mktemp)
  timeout 5s "$qfitzah" < "$case_dir/rule-directive.qf1" > "$output"

  while IFS= read -r snippet; do
    [[ -z "$snippet" ]] && continue
    if ! grep -aFq "$snippet" "$output"; then
      printf 'FAIL rule-directive: expected to find %q in output:\n' "$snippet" >&2
      cat "$output" >&2
      rm -f "$output"
      exit 1
    fi
  done < "$case_dir/rule-directive.expected"

  rm -f "$output"
  printf 'ok - rule-directive\n'
}

run_rule_directive

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

## Stage 3: the sc1 reader, Scheme running on scheme0.
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

## Stage 3: the sc1 Scheme-to-qfasm compiler. Each corpus case is compiled by
## interpreted sc1 (running under scheme0), assembled under the seed with the
## sc1 runtime, run, and its output diffed against the expected transcript.
sc1_reader="$repo_root/bootstrap/sc1-reader.scm"
sc1_scm="$repo_root/bootstrap/sc1.scm"
sc1_runtime="$repo_root/bootstrap/sc1-runtime.qf1"

run_sc1_case() {
  local name=$1
  local qfasm elf actual
  qfasm=$scheme0_dir/$name.qfasm
  elf=$scheme0_dir/$name.elf
  actual=$scheme0_dir/$name.out
  cat "$sc1_reader" "$sc1_scm" "$case_dir/$name.scm" \
    | timeout 120s "$scheme0_elf" > "$qfasm"
  cat "$repo_root/bootstrap/qfasm.qf1" "$sc1_runtime" "$qfasm" \
    | timeout 300s "$qfitzah" > "$elf"
  chmod +x "$elf"
  set +e
  timeout 60s "$elf" > "$actual"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf 'FAIL %s: compiled program exited %s\n' "$name" "$status" >&2
    cat "$actual" >&2
    exit 1
  fi
  if ! diff -u "$case_dir/$name.expected" "$actual" >&2; then
    printf 'FAIL %s: output differs\n' "$name" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$name"
}

run_sc1_case "sc1-corpus"
run_sc1_case "sc1-tail"

## The Stage 3 milestone: self-compilation to a byte-identical fixpoint.
## scheme0 interprets sc1 compiling sc1's own source (reader+compiler) to
## sc1.qfasm; the seed assembles that to the native sc1.elf; sc1.elf then
## compiles the same source and must produce byte-identical output.
run_sc1_fixpoint() {
  local q1 q2 elf
  q1=$scheme0_dir/sc1.qfasm
  q2=$scheme0_dir/sc1b.qfasm
  elf=$scheme0_dir/sc1.elf
  cat "$sc1_reader" "$sc1_scm" "$sc1_reader" "$sc1_scm" \
    | timeout 300s "$scheme0_elf" > "$q1"
  cat "$repo_root/bootstrap/qfasm.qf1" "$sc1_runtime" "$q1" \
    | timeout 900s "$qfitzah" > "$elf"
  chmod +x "$elf"
  cat "$sc1_reader" "$sc1_scm" | timeout 120s "$elf" > "$q2"
  if ! cmp "$q1" "$q2"; then
    printf 'FAIL sc1-fixpoint: sc1.elf output not byte-identical to sc1.qfasm\n' >&2
    exit 1
  fi
  printf 'ok - sc1-fixpoint (self-compile byte-identical)\n'
}

run_sc1_fixpoint

## Stage 4: the rsc R5RS-subset compiler. rsc.scm is written in the sc1 subset,
## so sc1.elf (built above, reused here) compiles it to rscA.elf. rsc then
## self-hosts: rscA compiles rsc.scm -> rscB.qfasm, rscB compiles rsc.scm ->
## rscC.qfasm, and rscB must equal rscC byte-for-byte. Finally an R5RS corpus
## (macros, quasiquote, vectors, apply, library) is compiled by rscA, assembled,
## run, and diffed.
rsc_scm="$repo_root/bootstrap/rsc.scm"
rsc_runtime="$repo_root/bootstrap/rsc-runtime.qf1"
RSC_ELF=""
# R5RS corpus cases.
RSC_CASES="rsc-macros rsc-derived rsc-library rsc-vectors rsc-apply"

run_rsc_fixpoint() {
  local sc1elf rscAqf rscBqf rscBelf rscCqf
  sc1elf=$scheme0_dir/sc1.elf            # built by run_sc1_fixpoint, reused
  # sc1.elf compiles rsc.scm -> rscA.elf.
  rscAqf=$scheme0_dir/rscA.qfasm
  cat "$sc1_reader" "$rsc_scm" | timeout 120s "$sc1elf" > "$rscAqf"
  RSC_ELF=$scheme0_dir/rscA.elf
  cat "$repo_root/bootstrap/qfasm.qf1" "$rsc_runtime" "$rscAqf" \
    | timeout 900s "$qfitzah" > "$RSC_ELF"
  chmod +x "$RSC_ELF"
  # Fixpoint: rscA -> rscB.qfasm, rscB -> rscC.qfasm, require rscB == rscC.
  rscBqf=$scheme0_dir/rscB.qfasm
  rscBelf=$scheme0_dir/rscB.elf
  rscCqf=$scheme0_dir/rscC.qfasm
  cat "$sc1_reader" "$rsc_scm" | timeout 120s "$RSC_ELF" > "$rscBqf"
  cat "$repo_root/bootstrap/qfasm.qf1" "$rsc_runtime" "$rscBqf" \
    | timeout 900s "$qfitzah" > "$rscBelf"
  chmod +x "$rscBelf"
  cat "$sc1_reader" "$rsc_scm" | timeout 120s "$rscBelf" > "$rscCqf"
  if ! cmp "$rscBqf" "$rscCqf"; then
    printf 'FAIL rsc-fixpoint: rscB.qfasm not byte-identical to rscC.qfasm\n' >&2
    exit 1
  fi
  printf 'ok - rsc-fixpoint (self-compile byte-identical)\n'
}

run_rsc_case() {
  local name=$1
  local qfasm elf actual
  qfasm=$scheme0_dir/$name.qfasm
  elf=$scheme0_dir/$name.elf
  actual=$scheme0_dir/$name.out
  cat "$repo_root/bootstrap/rsc-prelude.scm" "$case_dir/$name.scm" | timeout 60s "$RSC_ELF" > "$qfasm"
  cat "$repo_root/bootstrap/qfasm.qf1" "$rsc_runtime" "$qfasm" \
    | timeout 300s "$qfitzah" > "$elf"
  chmod +x "$elf"
  set +e
  timeout 60s "$elf" > "$actual"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf 'FAIL %s: compiled program exited %s\n' "$name" "$status" >&2
    cat "$actual" >&2
    exit 1
  fi
  if ! diff -u "$case_dir/$name.expected" "$actual" >&2; then
    printf 'FAIL %s: output differs\n' "$name" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$name"
}

run_rsc_fixpoint
for rsc_case in $RSC_CASES; do
  run_rsc_case "$rsc_case"
done

rm -rf "$scheme0_dir"

printf 'all tests passed\n'
