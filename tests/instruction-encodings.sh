#!/usr/bin/env bash
# Check instruction bytes, widths and descriptor coverage.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 SEED [SOURCE_ROOT]" >&2
  exit 2
fi
seed=$1
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
b=${2:-$root}/bootstrap
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixture=$root/tests/cases/instruction-encodings.tsv
awk '/^\(Describe / {sub(/^\(Describe \(/, ""); sub(/[ )].*/, ""); print}' \
  "$b/qfasm.qf1" "$b/runtime-support.qf1" | sort > "$tmp/descriptors"
awk '!/^#/ && NF {split($0, a, /[() ]/); print a[2]}' "$fixture" | sort > "$tmp/cases"
diff -u "$tmp/descriptors" "$tmp/cases"
cat "$b/qfasm.qf1" "$b/runtime-support.qf1" > "$tmp/bytes-input"
cp "$tmp/bytes-input" "$tmp/size-input"
printf '%s\n' '(InstructionBytes (Packed n fields)) (Bytes (OutFields fields (Small 0) (Bind Target (Small 0) Empty)))' >> "$tmp/bytes-input"
: > "$tmp/bytes-expected"
: > "$tmp/size-expected"
while IFS='|' read -r instruction expected; do
  [[ -z "$instruction" || "$instruction" == \#* ]] && continue
  read -r -a bytes <<< "$expected"
  for byte in "${bytes[@]}"; do
    [[ "$byte" =~ ^[0-9a-f]{2}$ ]]
    printf '%b' "\\x$byte" >> "$tmp/bytes-expected"
  done
  printf '(InstructionBytes (Seal (Describe %s)))\n' "$instruction" >> "$tmp/bytes-input"
  printf '(Size %s)\n' "$instruction" >> "$tmp/size-input"
  printf '(N %X 0 0 0 0 0 0 0)\n' "${#bytes[@]}" >> "$tmp/size-expected"
done < "$fixture"
timeout 30s "$seed" < "$tmp/bytes-input" > "$tmp/bytes-actual"
cmp "$tmp/bytes-expected" "$tmp/bytes-actual"
timeout 30s "$seed" < "$tmp/size-input" > "$tmp/size-actual"
diff -u "$tmp/size-expected" "$tmp/size-actual"
printf 'ok - every-instruction-encoding-and-width\n'
