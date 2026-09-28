#!/usr/bin/env bash
# Adversarial boundary tests; shell arithmetic is a test oracle, not a builder.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_QFITZAH" >&2
  exit 2
fi
qfitzah=$1
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Exercise every byte, including NUL, and nested byte streams. The digits
# are computed as terms, not pasted together into pre-existing byte atoms.
printf '(Digit x) x\n(Bytes\n' > "$tmp/input"
for ((hi=0; hi<16; hi++)); do
  printf ' (Bytes' >> "$tmp/input"
  for ((lo=0; lo<16; lo++)); do
    printf ' (Hex (Digit %X) (Digit %X))' "$hi" "$lo" >> "$tmp/input"
  done
  printf ')\n' >> "$tmp/input"
done
printf ')\n' >> "$tmp/input"
timeout 5s "$qfitzah" < "$tmp/input" > "$tmp/actual"
: > "$tmp/expected"
for ((byte=0; byte<256; byte++)); do
  printf -v octal '%03o' "$byte"
  printf '%b' "\\$octal" >> "$tmp/expected"
done
cmp "$tmp/expected" "$tmp/actual"
printf 'ok - computed-byte-exhaustive\n'
printf '(Bytes' > "$tmp/input"
for ((byte=0; byte<256; byte++)); do
  printf ' %02X' "$byte" >> "$tmp/input"
done
printf ')\n' >> "$tmp/input"
timeout 5s "$qfitzah" < "$tmp/input" > "$tmp/actual"
cmp "$tmp/expected" "$tmp/actual"
printf 'ok - literal-byte-exhaustive\n'

reject_bytes() {
  local term=$1 status=0
  { cat "$repo_root/bootstrap/qfasm.qf1"; printf '%s\n' "$term"; } > "$tmp/input"
  timeout 10s "$qfitzah" < "$tmp/input" > "$tmp/actual" 2> "$tmp/error" || status=$?
  if [[ $status -ne 1 || -s "$tmp/actual" ]] ||
      ! grep -qx 'qfitzah: invalid byte output' "$tmp/error"; then
    printf 'FAIL byte rejection (status %s): %s\n' "$status" "$term" >&2
    exit 1
  fi
}
# Valid prefix bytes must not leak from the failing record. No crashes,
# timeout, unresolved-term-to-pointer conversion, or successful junk output.
for bad in '()' '0' '000' 'GG' '0G' 'ff' 'unbound' '(Unknown FF)' \
    '(Hex)' '(Hex F)' '(Hex F F F)' '(Hex FF 0)' '(Hex F G)' \
    '(Hex () F)' '(Hex (Unknown) F)' '(Hex F ())' '(Hex F (Unknown))'; do
  reject_bytes "(Bytes 7F (Bytes 45 $bad))"
done
reject_bytes '(Bytes (Rel8 (X8 0 0 0 0 0 0 8 0)))'
reject_bytes '(Bytes (Rel8 (X8 F F F F F F 7 F)))'
reject_bytes '(Assemble (Program Missing (Ins (Label Start) (Ins (Ret) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (Unknown) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (MovRM EAX ESP) End))))'
printf 'ok - invalid-bytes-and-assembly-rejected\n'

# Independent exhaustive oracle for the small arithmetic building block.
cat "$repo_root/bootstrap/qfasm.qf1" > "$tmp/input"
: > "$tmp/expected"
for ((carry=0; carry<2; carry++)); do
  cin=O
  [[ $carry -eq 0 ]] || cin=I
  for ((a=0; a<16; a++)); do
    for ((b=0; b<16; b++)); do
      printf '(AD %s %X %X)\n' "$cin" "$a" "$b" >> "$tmp/input"
      sum=$((a+b+carry))
      cout=O
      [[ $sum -lt 16 ]] || cout=I
      printf '(P %X %s)\n' "$((sum%16))" "$cout" >> "$tmp/expected"
    done
  done
done
timeout 30s "$qfitzah" < "$tmp/input" > "$tmp/actual"
diff -u "$tmp/expected" "$tmp/actual"
printf 'ok - nybble-add-exhaustive\n'

{ cat "$repo_root/bootstrap/qfasm.qf1";
  printf '(Bytes (Rel8 (X8 0 0 0 0 0 0 7 F)) (Rel8 (X8 F F F F F F 8 0)))\n';
} > "$tmp/input"
timeout 5s "$qfitzah" < "$tmp/input" > "$tmp/actual"
printf '\177\200' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/actual"
printf 'ok - rel8-boundaries\n'
