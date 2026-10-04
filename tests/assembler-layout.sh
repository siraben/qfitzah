#!/usr/bin/env bash
# Check alignment, ELF fields and relative operands.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 SEED" >&2
  exit 2
fi
seed=$1
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat "$root/bootstrap/qfasm.qf1" "$root/bootstrap/runtime-support.qf1" > "$tmp/library"
assemble() {
  cat "$tmp/library" "$tmp/program" | timeout 10s "$seed" > "$tmp/elf"
}
word_at() { od -An -tu4 -j "$1" -N4 "$tmp/elf" | tr -d '[:space:]'; }
body_hex() { od -An -tx1 -v -j88 "$tmp/elf" | tr -d '[:space:]'; }
for align in 4 8; do
  for ((residue=0; residue<align; residue++)); do
    {
      printf '(Assemble (Program (Local Test Entry) (Small F) (Block (\n'
      for ((i=0; i<residue; i++)); do printf '(Db AA)\n'; done
      printf '(Align%s) (Label (Local Test Entry)) (Ret)) End)))\n' "$align"
    } > "$tmp/program"
    assemble
    aligned=$(((residue+align-1)/align*align))
    size=$((88+aligned+1))
    [[ $(wc -c < "$tmp/elf") -eq $size ]]
    [[ $(word_at 24) -eq $((0x08048058+aligned)) ]]
    [[ $(word_at 68) -eq $size ]]
    [[ $(word_at 72) -eq $((size+15)) ]]
    expected=""
    for ((i=0; i<residue; i++)); do expected+=aa; done
    for ((i=residue; i<aligned; i++)); do expected+="00"; done
    [[ $(body_hex) == "${expected}c3" ]]
  done
done
printf 'ok - alignment-and-elf-fields\n'

for direction in forward backward; do
  for edge in valid invalid; do
    {
      printf '(Assemble (Program Start (Block ((Label Start)\n'
      if [[ $direction == forward ]]; then
        printf '(JmpS Target)\n'
        count=127
        [[ $edge == valid ]] || count=128
      else
        printf '(Label Target)\n'
        count=126
        [[ $edge == valid ]] || count=127
      fi
      for ((i=0; i<count; i++)); do printf '(Nop)\n'; done
      if [[ $direction == forward ]]; then
        printf '(Label Target)\n'
      else
        printf '(JmpS Target)\n'
      fi
      printf '(Ret)) End)))\n'
    } > "$tmp/program"
    if [[ $edge == invalid ]]; then
      status=0
      assemble 2> "$tmp/error" || status=$?
      [[ $status -eq 1 && ! -s "$tmp/elf" ]]
      grep -qx 'qfitzah: invalid byte output' "$tmp/error"
    else
      assemble
      if [[ $direction == forward ]]; then
        [[ $(od -An -tx1 -j89 -N1 "$tmp/elf" | tr -d '[:space:]') == 7f ]]
      else
        [[ $(od -An -tx1 -j215 -N1 "$tmp/elf" | tr -d '[:space:]') == 80 ]]
      fi
    fi
  done
done
printf 'ok - assembled-rel8-boundaries\n'
printf '%s\n' '(Assemble (Program Start (Block ((Label Start) (Jz32 Target) (Nop) (Label Target) (Ret)) End)))' > "$tmp/program"
assemble
[[ $(body_hex) == 0f840100000090c3 ]]
printf '%s\n' '(Assemble (Program Target (Block ((Label Target) (Nop) (Call Target) (Ret)) End)))' > "$tmp/program"
assemble
[[ $(body_hex) == 90e8faffffffc3 ]]
printf 'ok - relative-to-whole-instruction-end\n'
