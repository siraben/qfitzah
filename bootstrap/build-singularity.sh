#!/usr/bin/env bash
# Build a source compiler for Blynn's initial untyped language through rsc.
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
    "$b/blynn/singularity-reader.scm" "$b/blynn/singularity-compile.scm" \
    "$b/blynn/singularity-main.scm" | "$compiler" > "$out/singularity.qfasm"
bash "$b/assemble.sh" "$seed" rsc "$out/singularity.qfasm" > "$out/singularity"
chmod +x "$out/singularity"
sha256sum "$out/singularity" > "$out/singularity.sha256"
printf '%s\n' "$out/singularity"
