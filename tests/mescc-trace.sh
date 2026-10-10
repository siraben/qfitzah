#!/usr/bin/env bash
# Logging must not change emitted M1 or leak trace text into stdout.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "usage: $0 MES_HOST MES_SOURCE GENERATED_NYACC" >&2; exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
nyacc=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-mescc-trace.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "trace artifacts: $work" >&2; fi' EXIT
args=("$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" -S --arch x86 -m32
      -DEXPECTED=42 -o "$work/probe.M1" "$root/tests/cases/mescc-exit.c")
timeout 120s env -u QFITZAH_MESCC_TRACE -u QFITZAH_MESCC_AST_OUTPUT \
  bash "${args[@]}" > "$work/plain.out" 2> "$work/plain.err"
cp "$work/probe.M1" "$work/plain.M1"
# Generated-transformer analysis must preserve actual C-to-M1 bytes as well
# as Scheme-level macro results. Use the same source/output paths in both modes.
timeout 120s env -u QFITZAH_MESCC_TRACE -u QFITZAH_MESCC_AST_OUTPUT \
  QFITZAH_DISABLE_ANALYSIS=1 bash "${args[@]}" > "$work/reference.out" 2> "$work/reference.err"
cmp "$work/plain.M1" "$work/probe.M1"
cmp "$work/plain.out" "$work/reference.out"
timeout 120s env QFITZAH_MESCC_TRACE=1 QFITZAH_MESCC_HEAP_TRACE=1 \
  QFITZAH_MESCC_AST_OUTPUT="$work/probe.E" \
  bash "${args[@]}" > "$work/traced.out" 2> "$work/traced.err"
cmp "$work/plain.M1" "$work/probe.M1"
cmp "$work/plain.out" "$work/traced.out"
names=('c99-input->full-ast' 'c99-ast->info' main 'infos->M1')
if [[ -n ${QFITZAH_MESCC_NORMALIZER:-} ]]; then
  names+=(native-normalize)
else
  names+=('c99-input->ast')
fi
for name in "${names[@]}"; do
  grep -Fq "mescc: $name begin; retained-8-byte-units=" "$work/traced.err"
  grep -Fq "mescc: $name done; retained-8-byte-units=" "$work/traced.err"
done
grep -qx 'qfitzah-mescc-ast-v1' "$work/probe.E.complete"
# Replay the saved frontend data through the upstream .E backend, never through
# a host compiler. The output path is unchanged to preserve M1 file comments.
timeout 120s env -u QFITZAH_MESCC_TRACE -u QFITZAH_MESCC_AST_OUTPUT \
  bash "$root/bootstrap/mescc.sh" "$host" "$mes" "$nyacc" \
  -S --arch x86 -m32 -o "$work/probe.M1" "$work/probe.E"
cmp "$work/plain.M1" "$work/probe.M1"
# A stale complete marker must never authorize replacing an existing AST.
status=0
timeout 120s env QFITZAH_MESCC_TRACE=1 QFITZAH_MESCC_AST_OUTPUT="$work/probe.E" \
  bash "${args[@]}" > "$work/rejected.out" 2> "$work/rejected.err" || status=$?
test "$status" = 1
grep -q 'AST checkpoint destination already exists' "$work/rejected.err"
echo 'ok - MesCC analyzed/reference transformers, tracing and AST replay preserve M1'
