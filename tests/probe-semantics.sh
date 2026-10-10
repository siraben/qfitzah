#!/usr/bin/env bash
# Tests for known Scheme bugs; exits nonzero on failures.
# Run separately from tests/run.sh.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_QFITZAH" >&2
  exit 2
fi
qfitzah=$1
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ulimit -c 0
b=$root/bootstrap

assemble() {
  local runtime=$1 source=$2 elf=$3
  cat "$b/qfasm.qf1" "$b/runtime-support.qf1" "$b/gc.qf1" "$b/io.qf1" \
      "$b/control.qf1" "$b/lookup.qf1" "$runtime" "$source" | timeout 900s "$qfitzah" > "$elf"
  chmod +x "$elf"
}
cat "$b/qfasm.qf1" "$b/runtime-support.qf1" "$b/scheme0.qfasm" | timeout 120s "$qfitzah" > "$tmp/scheme0"
chmod +x "$tmp/scheme0"
cat "$b/sc1-reader.scm" "$b/sc1.scm" "$b/sc1-reader.scm" "$b/sc1.scm" \
  | timeout 300s "$tmp/scheme0" > "$tmp/sc1.qfasm"
assemble "$b/sc1-runtime.qf1" "$tmp/sc1.qfasm" "$tmp/sc1"
cat "$b/sc1-reader.scm" "$b/rsc.scm" | timeout 120s "$tmp/sc1" > "$tmp/rsc.qfasm"
assemble "$b/rsc-runtime.qf1" "$tmp/rsc.qfasm" "$tmp/rsc"

failures=0
probe() {
  local compiler=$1 name=$2 status=0
  timeout 120s "$tmp/$compiler" < "$root/tests/probes/$name.scm" > "$tmp/probe.qfasm"
  assemble "$b/$compiler-runtime.qf1" "$tmp/probe.qfasm" "$tmp/probe"
  # Constrain only the program, not the compiler or assembler. A direct-if
  # control distinguishes stack-limit incompatibility from lost tail position.
  (ulimit -s 256; timeout 10s "$tmp/probe") > "$tmp/actual" 2> "$tmp/error" || status=$?
  if [[ $status -ne 0 ]]; then
    printf 'FAIL %s/%s: executable status %s\n' "$compiler" "$name" "$status"
    cat "$tmp/actual" "$tmp/error"
    failures=$((failures+1))
  elif ! diff -u "$root/tests/probes/$name.expected" "$tmp/actual"; then
    printf 'FAIL %s/%s: semantic mismatch\n' "$compiler" "$name"
    failures=$((failures+1))
  else
    printf 'ok - %s/%s\n' "$compiler" "$name"
  fi
}
for compiler in sc1 rsc; do
  probe "$compiler" core-semantics
  probe "$compiler" tail-if
  probe "$compiler" tail-or
done
for name in macro-definition macro-quote macro-literal macro-string apply-binding apply-rest; do
  probe rsc "$name"
done
printf '%s failing semantic probes\n' "$failures"
[[ $failures -eq 0 ]]
