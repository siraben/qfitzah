#!/usr/bin/env bash
# Seed and assembler boundary tests.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_QFITZAH" >&2
  exit 2
fi
qfitzah=$1
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Exercise every byte, including NUL, with computed digits and nested streams.
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
# A failed record must exit with status 1 and emit no bytes.
for bad in '()' '0' '000' 'GG' '0G' 'ff' 'unbound' '(Unknown FF)' \
    '(Hex)' '(Hex F)' '(Hex F F F)' '(Hex FF 0)' '(Hex F G)' \
    '(Hex () F)' '(Hex (Unknown) F)' '(Hex F ())' '(Hex F (Unknown))'; do
  reject_bytes "(Bytes 7F (Bytes 45 $bad))"
done
reject_bytes '(Assemble)'
reject_bytes '(Assemble Unknown)'
reject_bytes '(Assemble (Program Start))'
reject_bytes '(Assemble (Program Start End) Extra)'
reject_bytes '(Assemble . Junk)'
reject_bytes '(Bytes (Rel8 (X8 0 0 0 0 0 0 8 0)))'
reject_bytes '(Bytes (Rel8 (X8 F F F F F F 7 F)))'
reject_bytes '(Assemble (Program Missing (Ins (Label Start) (Ins (Ret) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (Unknown) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (MovRM EAX ESP) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (Db (Bytes 00 00)) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (Db (Bytes)) End))))'
reject_bytes '(Assemble (Program Start (Ins (Label Start) (Ins (Int (Bytes 80 90)) End))))'
reject_bytes '(Bytes 00 . FF)'
reject_bytes '(Bytes . FF)'
reject_bytes '(Bytes (Hex A . B))'
printf 'ok - invalid-bytes-and-assembly-rejected\n'

# Reject malformed records, dotted tails and input NULs.
for bad in '.' '(. A)' '(A .)' '(A . B C)' '(A . .)' '(A . B . C)' \
    '(A' '(A))' '(Rule)' '(Rule A)' '(Rule A B C)' '(Rule A . B)' \
    '(F x) x Extra' 'A\0 B\n' '(A\0 B)\n' '; comment\0 suffix\n'; do
  printf '%b' "$bad" > "$tmp/input"
  status=0
  timeout 5s "$qfitzah" < "$tmp/input" > "$tmp/actual" 2> "$tmp/error" || status=$?
  if [[ $status -ne 1 || -s "$tmp/actual" ]] ||
      ! grep -qx 'qfitzah: invalid input' "$tmp/error"; then
    printf 'FAIL syntax rejection (status %s): %s\n' "$status" "$bad" >&2
    exit 1
  fi
done
printf 'ok - malformed-records-rejected\n'

# Check all nybble sums and carry inputs against shell arithmetic.
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

# Check every supported ModRM and register-in-opcode combination.
cat "$repo_root/bootstrap/qfasm.qf1" > "$tmp/input"
: > "$tmp/expected"
encoding_case() {
  local expression=$1 value=$2 octal
  printf '(Bytes %s)\n' "$expression" >> "$tmp/input"
  printf -v octal '%03o' "$value"
  printf '%b' "\\$octal" >> "$tmp/expected"
}
registers=(EAX ECX EDX EBX ESP EBP ESI EDI)
for ((reg=0; reg<8; reg++)); do
  for ((rm=0; rm<8; rm++)); do
    encoding_case "(RM11 ${registers[reg]} ${registers[rm]})" "$((192+8*reg+rm))"
    encoding_case "(RMX $reg ${registers[rm]})" "$((192+8*reg+rm))"
    if [[ $rm -ne 4 && $rm -ne 5 ]]; then
      encoding_case "(RM00 ${registers[rm]} ${registers[reg]})" "$((8*reg+rm))"
    fi
    if [[ $rm -ne 4 ]]; then
      encoding_case "(RM01 ${registers[rm]} ${registers[reg]})" "$((64+8*reg+rm))"
    fi
  done
  encoding_case "(RM05 ${registers[reg]})" "$((8*reg+5))"
  encoding_case "(IncB ${registers[reg]})" "$((64+reg))"
  encoding_case "(DecB ${registers[reg]})" "$((72+reg))"
  encoding_case "(PushB ${registers[reg]})" "$((80+reg))"
  encoding_case "(PopB ${registers[reg]})" "$((88+reg))"
  encoding_case "(MovIB ${registers[reg]})" "$((184+reg))"
  encoding_case "(XchgAB ${registers[reg]})" "$((144+reg))"
done
timeout 30s "$qfitzah" < "$tmp/input" > "$tmp/actual"
cmp "$tmp/expected" "$tmp/actual"
reject_bytes '(Bytes (RM00 EBP EAX))'
reject_bytes '(Bytes (RM01 ESP EAX))'
reject_bytes '(Bytes (RMX 8 EAX))'
reject_bytes '(Bytes (RM11 Unknown EAX))'
printf 'ok - register-encodings-exhaustive\n'

{ cat "$repo_root/bootstrap/qfasm.qf1";
  printf '(Bytes (Rel8 (X8 0 0 0 0 0 0 7 F)) (Rel8 (X8 F F F F F F 8 0)))\n';
} > "$tmp/input"
timeout 5s "$qfitzah" < "$tmp/input" > "$tmp/actual"
printf '\177\200' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/actual"
printf 'ok - rel8-boundaries\n'
