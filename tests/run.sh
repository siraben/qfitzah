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
RSC_CASES="rsc-macros rsc-derived rsc-library rsc-vectors rsc-apply qmes-w32"

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

## P1 Part B: syscalls + argv/env. Unlike run_rsc_case this drives the
## compiled program with a known env var, argv, and datafile so the
## transcript is deterministic (argv[0] is a temp path and is never printed).
run_qmes_syscall() {
  local name=qmes-syscall
  local qfasm elf actual datafile
  qfasm=$scheme0_dir/$name.qfasm
  elf=$scheme0_dir/$name.elf
  actual=$scheme0_dir/$name.out
  datafile=$scheme0_dir/$name.data
  printf 'datafile-contents-9x7' > "$datafile"
  cat "$repo_root/bootstrap/rsc-prelude.scm" "$case_dir/$name.scm" \
    | timeout 60s "$RSC_ELF" > "$qfasm"
  cat "$repo_root/bootstrap/qfasm.qf1" "$rsc_runtime" "$qfasm" \
    | timeout 300s "$qfitzah" > "$elf"
  chmod +x "$elf"
  set +e
  env -u QMES_ABSENT_VAR_XYZ QMES_TESTVAR=hello-qmes-env \
    timeout 60s "$elf" ARG_ALPHA ARG_BETA "$datafile" > "$actual"
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

run_qmes_syscall

## P1 Part C gate: host-heap reclamation. A 50-million-iteration trampoline
## soak that must complete in constant memory (it would OOM/SIGSEGV if the
## arena reset did not reclaim). Dedicated runner for a generous run timeout.
run_qmes_soak() {
  local name=qmes-heap-soak
  local qfasm elf actual
  qfasm=$scheme0_dir/$name.qfasm
  elf=$scheme0_dir/$name.elf
  actual=$scheme0_dir/$name.out
  cat "$repo_root/bootstrap/rsc-prelude.scm" "$case_dir/$name.scm" \
    | timeout 60s "$RSC_ELF" > "$qfasm"
  cat "$repo_root/bootstrap/qfasm.qf1" "$rsc_runtime" "$qfasm" \
    | timeout 300s "$qfitzah" > "$elf"
  chmod +x "$elf"
  set +e
  timeout 180s "$elf" > "$actual"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf 'FAIL %s: soak exited %s (OOM/segfault => reset did not reclaim)\n' \
      "$name" "$status" >&2
    cat "$actual" >&2
    exit 1
  fi
  if ! diff -u "$case_dir/$name.expected" "$actual" >&2; then
    printf 'FAIL %s: output differs\n' "$name" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$name"
}

run_qmes_soak

## P2 milestone gate: the qmes interpreter boot ladder.  Compile bootstrap/
## qmes.scm with rsc, assemble it under the seed, then run each of Mes's
## scaffold boot files 00-zero..14-exit under MES_BOOT and compare the exit
## status of every one against the committed reference (tests/mes-reference-
## bootstatus.txt, produced by bin/mes-m2).  A single divergence fails.
# asm.elf: rsc compiles bootstrap/asm.scm; the seed assembles it once (~39k
# instrs, under the seed's arena ceiling).  Built once, reused by the qmes boot
# ladder and asm-validate.  qmes itself has outgrown the seed ceiling (S1's
# fidelity refit pushed it well past ~66k qfasm instrs), so qmes.elf is
# assembled by asm.elf, not the seed.
asm_elf=""
asm_qfasm=""
asm_runtime_flat="$repo_root/bootstrap/asm-runtime.flat"
build_asm_elf() {
  asm_qfasm=$scheme0_dir/asm.qfasm
  asm_elf=$scheme0_dir/asm.elf
  [ -x "$asm_elf" ] && return 0
  cat "$repo_root/bootstrap/rsc-prelude.scm" "$repo_root/bootstrap/asm.scm" \
    | timeout 120s "$RSC_ELF" > "$asm_qfasm"
  cat "$repo_root/bootstrap/qfasm.qf1" "$rsc_runtime" "$asm_qfasm" \
    | timeout 300s "$qfitzah" > "$asm_elf"
  chmod +x "$asm_elf"
}

run_qmes_boot_ladder() {
  local qfasm elf actual
  qfasm=$scheme0_dir/qmes.qfasm
  elf=$scheme0_dir/qmes.elf
  actual=$scheme0_dir/qmes-bootstatus.txt
  cat "$repo_root/bootstrap/rsc-prelude.scm" "$repo_root/bootstrap/qmes.scm" \
    | timeout 120s "$RSC_ELF" > "$qfasm"
  build_asm_elf
  "$asm_elf" "$asm_runtime_flat" < "$qfasm" > "$elf"
  chmod +x "$elf"
  local boot_dir="$repo_root/third_party/mes/scaffold/boot"
  local prefix="$repo_root/third_party/mes"
  : > "$actual"
  local t st
  for t in 00-zero 01-true 02-identifier 02-symbol 03-big-string 03-string \
           04-cons 04-quote 05-big-list 05-list-list 05-list 06-tick 07-if \
           08-if-if 10-cons 11-list 11-vector 12-car 13-cdr 14-exit 15-display \
           16-if-eq-quote 17-equal2 17-memq-keyword 17-memq 17-string-append \
           17-string-equal 20-define-quoted 20-define-quote 20-define \
           21-define-procedure 22-define-procedure-2 23-begin 24-begin-define \
           25-begin-define-2 26-begin-define-later 26-define-define \
           27-lambda-define 28-define-define 29-lambda-define 2a-lambda-lambda \
           2b-define-lambda 2c-define-lambda-recurse 2d-compose \
           2d-define-lambda-set 2e-define-first 2f-define-second-lambda \
           2f-define-second 2g-vector 30-capture 31-capture-define \
           32-capture-modify-close 33-procedure-override-close \
           34-cdr-override-close 35-closure-modify 36-closure-override \
           37-closure-lambda 39-global-define-override \
           3a-global-define-lambda-override; do
    set +e
    env MES_BOOT="$boot_dir/$t.scm" MES_PREFIX="$prefix" \
      timeout 30s "$elf" >/dev/null 2>&1
    st=$?
    set -e
    printf '%s -> %s\n' "$t" "$st" >> "$actual"
  done
  if ! diff -u "$repo_root/tests/mes-reference-bootstatus.txt" "$actual" >&2; then
    printf 'FAIL qmes-boot-ladder: exit statuses diverge from mes-m2 reference\n' >&2
    exit 1
  fi
  printf 'ok - qmes-boot-ladder (00-zero..3a match mes-m2)\n'
}

run_qmes_boot_ladder

## The native assembler asm.elf: rsc compiles bootstrap/asm.scm; the seed
## assembles it once (~39k instrs).  asm.elf must then produce byte-identical
## ELFs to [seed + qfasm.qf1 (+ runtime)] on a broad battery -- the qfasm
## fixtures, sc1's output, rsc's output and the 65.9k-instr qmes -- plus the
## asm.elf self-fixpoint (it reassembles its own asm.qfasm to itself).  These
## reuse the qfasm/ELF artifacts already built by the fixpoint stages above.
run_asm_validate() {
  local out
  local rsc_flat="$repo_root/bootstrap/asm-runtime.flat"
  local sc1_flat="$repo_root/bootstrap/sc1-asm-runtime.flat"

  # asm.elf was built by build_asm_elf (during the qmes boot ladder); reuse it.
  build_asm_elf

  # Byte-identical differential: asm.elf output == seed-pipeline output.
  asm_diff() { # asm_diff NAME QFASM SEED_ELF [FLAT]
    local name=$1 qfasm=$2 seedelf=$3 flat=${4:-}
    out=$scheme0_dir/$name.asm.elf
    "$asm_elf" $flat < "$qfasm" > "$out"
    if ! cmp -s "$seedelf" "$out"; then
      printf 'FAIL asm-validate %s: asm.elf output differs from the seed pipeline\n' "$name" >&2
      exit 1
    fi
    printf 'ok - asm-validate %s (byte-identical to seed)\n' "$name"
  }
  # bare qfasm fixtures: compare against the seed directly
  local se
  for name in qfasm-exit42 qfasm-big; do
    se=$scheme0_dir/$name.seed.elf
    cat "$repo_root/bootstrap/qfasm.qf1" "$case_dir/$name.qfasm" \
      | timeout 120s "$qfitzah" > "$se"
    asm_diff "$name" "$case_dir/$name.qfasm" "$se"
  done
  # staged outputs (runtime programs) vs the seed-built ELFs from the fixpoints.
  # (No qmes case: qmes has outgrown the seed's arena ceiling, so there is no
  # seed-built qmes.elf to diff against; asm.elf correctness is covered by
  # sc1/rscA byte-identity + the self-fixpoint below.  qmes.elf is asm.elf-built
  # and exercised end-to-end by the boot ladder above.)
  asm_diff sc1  "$scheme0_dir/sc1.qfasm"  "$scheme0_dir/sc1.elf"  "$sc1_flat"
  asm_diff rscA "$scheme0_dir/rscA.qfasm" "$scheme0_dir/rscA.elf" "$rsc_flat"

  # self-fixpoint: asm.elf reassembling its own qfasm reproduces asm.elf.
  local asm2=$scheme0_dir/asm2.elf
  "$asm_elf" "$rsc_flat" < "$asm_qfasm" > "$asm2"
  if ! cmp -s "$asm_elf" "$asm2"; then
    printf 'FAIL asm-validate self-fixpoint: asm.elf does not reassemble to itself\n' >&2
    exit 1
  fi
  printf 'ok - asm-validate self-fixpoint (asm.elf reassembles itself)\n'
}

run_asm_validate

rm -rf "$scheme0_dir"

printf 'all tests passed\n'
