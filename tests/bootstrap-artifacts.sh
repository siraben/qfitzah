#!/usr/bin/env bash
# Build all four stage executables and print their hashes.
# OUTPUT_DIR must not exist. SOURCE_ROOT defaults to this checkout.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 SEED OUTPUT_DIR [SOURCE_ROOT]" >&2
  exit 2
fi
seed=$(realpath "$1")
root=${3:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
b=$root/bootstrap
mkdir -- "$2"
out=$(cd -- "$2" && pwd)
assemble() {
  local stage=$1 input=$2 output=$3
  timeout 900s bash "$b/assemble.sh" "$seed" "$stage" "$input" > "$output"
  chmod +x "$output"
}
assemble scheme0 "$b/scheme0.qfasm" "$out/scheme0.elf"
cat "$b/sc1-reader.scm" "$b/sc1.scm" "$b/sc1-reader.scm" "$b/sc1.scm" \
  | timeout 300s "$out/scheme0.elf" > "$out/sc1.qfasm"
assemble sc1 "$out/sc1.qfasm" "$out/sc1.elf"
cat "$b/sc1-reader.scm" "$b/rsc.scm" | timeout 120s "$out/sc1.elf" > "$out/rscA.qfasm"
assemble rsc "$out/rscA.qfasm" "$out/rscA.elf"
cat "$b/sc1-reader.scm" "$b/rsc.scm" | timeout 120s "$out/rscA.elf" > "$out/rscB.qfasm"
assemble rsc "$out/rscB.qfasm" "$out/rscB.elf"
(cd -- "$out" && sha256sum ./*.elf)
