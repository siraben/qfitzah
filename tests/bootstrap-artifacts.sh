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
sources=("$b/qfasm.qf1")
# Older checkouts do not have runtime-support.qf1.
if [[ -f "$b/runtime-support.qf1" ]]; then
  sources+=("$b/runtime-support.qf1")
fi
mkdir -- "$2"
out=$(cd -- "$2" && pwd)
assemble() {
  local runtime=$1 input=$2 output=$3
  cat "${sources[@]}" "$runtime" "$input" | timeout 900s "$seed" > "$output"
  chmod +x "$output"
}
cat "${sources[@]}" "$b/scheme0.qfasm" | timeout 300s "$seed" > "$out/scheme0.elf"
chmod +x "$out/scheme0.elf"
cat "$b/sc1-reader.scm" "$b/sc1.scm" "$b/sc1-reader.scm" "$b/sc1.scm" \
  | timeout 300s "$out/scheme0.elf" > "$out/sc1.qfasm"
assemble "$b/sc1-runtime.qf1" "$out/sc1.qfasm" "$out/sc1.elf"
cat "$b/sc1-reader.scm" "$b/rsc.scm" | timeout 120s "$out/sc1.elf" > "$out/rscA.qfasm"
assemble "$b/rsc-runtime.qf1" "$out/rscA.qfasm" "$out/rscA.elf"
cat "$b/sc1-reader.scm" "$b/rsc.scm" | timeout 120s "$out/rscA.elf" > "$out/rscB.qfasm"
assemble "$b/rsc-runtime.qf1" "$out/rscB.qfasm" "$out/rscB.elf"
(cd -- "$out" && sha256sum ./*.elf)
