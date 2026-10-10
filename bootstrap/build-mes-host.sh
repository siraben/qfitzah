#!/usr/bin/env bash
# Build the in-progress Mes compatibility host using only rsc and qfitzah.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 SEED RSC_COMPILER NEW_OUTPUT_DIRECTORY [ASSEMBLY_OVERRIDES]" >&2
  exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -- "$3"
out=$(cd -- "$3" && pwd)
# rsc emits one byte per write; a copying pipe batches filesystem writes.
# pipefail still propagates compiler and output failures.
if ! cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" \
    "$b/rsc-integers.scm" "$b/rsc-reader.scm" \
    "$b/mes-host/identifiers.scm" "$b/mes-host/environment.scm" "$b/mes-host/evaluate.scm" \
    "$b/mes-host/syntax.scm" "$b/mes-host/analyze.scm" "$b/mes-host/derived.scm" \
    "$b/mes-host/primitives.scm" "$b/mes-host/lists.scm" \
    "$b/mes-host/strings.scm" "$b/mes-host/library.scm" \
    "$b/mes-host/charsets.scm" "$b/mes-host/format.scm" "$b/mes-host/records.scm" \
    "$b/mes-host/modules.scm" "$b/mes-host/main.scm" \
  | "$compiler" | cat > "$out/mes-host.qfasm"; then
  tail -n 5 "$out/mes-host.qfasm" >&2
  exit 1
fi
# Older rsc output hard-codes 256 MiB BSS, too small for the MesCC heap.
# Refuse it instead of producing an executable which corrupts unmapped memory.
if ! grep -Fq '(Program Start (GcMemoryBytes)' "$out/mes-host.qfasm"; then
  echo "rebuild rsc from current source: Mes host needs heap-sized ELF BSS" >&2
  exit 1
fi
args=("$seed" rsc "$out/mes-host.qfasm" "${4:-$b/mes-host/heap.qf1}")
bash "$b/assemble.sh" "${args[@]}" > "$out/mes-host"
chmod +x "$out/mes-host"
sha256sum "$out/mes-host"
