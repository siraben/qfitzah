#!/usr/bin/env bash
# Build a hex0 source assembler through rsc; no imported stage0 executable.
set -euo pipefail
if (( $# != 3 )); then
  echo "usage: $0 SEED RSC_COMPILER NEW_DIRECTORY" >&2; exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -- "$3"
out=$(realpath "$3")
cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" \
    "$b/blynn/hex0.scm" | "$compiler" > "$out/hex0.qfasm"
bash "$b/assemble.sh" "$seed" rsc "$out/hex0.qfasm" > "$out/hex0"
chmod +x "$out/hex0"
sha256sum "$out/hex0" > "$out/hex0.sha256"
printf '%s\n' "$out/hex0"
