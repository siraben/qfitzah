#!/usr/bin/env bash
# Source-built combined M1/hex2 assembler; no downstream host assembler/linker.
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
if ! cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" \
    "$b/rsc-integers.scm" "$b/m1/lex.scm" "$b/m1/layout.scm" \
    "$b/m1/link.scm" "$b/m1/main.scm" | "$compiler" > "$out/m1-link.qfasm"; then
  tail -n 5 "$out/m1-link.qfasm" >&2
  exit 1
fi
args=("$seed" rsc "$out/m1-link.qfasm")
if [[ $# == 4 ]]; then args+=("$4"); fi
bash "$b/assemble.sh" "${args[@]}" > "$out/m1-link"
chmod +x "$out/m1-link"
sha256sum "$out/m1-link"
