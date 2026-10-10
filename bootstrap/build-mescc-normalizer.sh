#!/usr/bin/env bash
# Compile the pinned compiler's actual normalization definitions through rsc.
set -euo pipefail
if (( $# != 5 )); then
  echo "usage: $0 SEED RSC_COMPILER MES_HOST MES_SOURCE NEW_DIRECTORY" >&2
  exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
host=$(realpath "$3")
mes=$(realpath "$4")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -- "$5"
out=$(realpath "$5")
"$host" --mes "$mes" "$b/mescc-native/source.scm" -- "$mes" > "$out/upstream.scm"
if ! cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" \
    "$b/rsc-integers.scm" "$b/rsc-reader.scm" "$b/mescc-native/primitives.scm" \
    "$out/upstream.scm" \
    "$b/mescc-native/main.scm" | "$compiler" | cat > "$out/normalize.qfasm"; then
  echo "normalizer compilation failed: $out/normalize.qfasm" >&2
  exit 1
fi
bash "$b/assemble.sh" "$seed" rsc "$out/normalize.qfasm" > "$out/normalize"
chmod +x "$out/normalize"
sha256sum "$out/normalize" > "$out/normalize.sha256"
printf '%s\n' "$out/normalize"
