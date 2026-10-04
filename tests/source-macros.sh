#!/usr/bin/env bash
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
{
  cat "$tmp/library"
  cat <<'QF'
(Block () End)
(Block ((Nop) (Splice ((Ret) (Splice ((Int 80)))))) End)
(AsciiData (C O N S))
(ListLength (C H A R - > I N T E G E R))
(ListLength (CorePrimitives))
(ListLength (RscPrimitives))
QF
} | timeout 10s "$seed" > "$tmp/actual"
cat > "$tmp/expected" <<'OUT'
End
(Ins (Nop) (Ins (Ret) (Ins (Int 80) End)))
((Db 63) (Db 6F) (Db 6E) (Db 73))
(N D 0 0 0 0 0 0 0)
(N 9 2 0 0 0 0 0 0)
(N 4 3 0 0 0 0 0 0)
OUT
diff -u "$tmp/expected" "$tmp/actual"

# The exit42 fixture, expressed as flat source
# with nested splices. This compares full ELF bytes, not just its exit status.
{
  cat "$tmp/library"
  cat <<'QF'
(Assemble (Program Entry (Small 0)
  (Block (
    (Label Entry)
    (MovRI EAX (Small 1))
    (Splice ((JmpS Skip) (Db DE)))
    (Label Skip)
    (MovRI EBX (X8 0 0 0 0 0 0 2 A))
    (Int 80)) End)))
QF
} | timeout 10s "$seed" > "$tmp/elf"
od -An -tx1 -v "$tmp/elf" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' > "$tmp/actual"
tr -s '[:space:]' ' ' < "$root/tests/cases/qfasm-exit42.hex" | sed 's/^ //; s/ $//' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/actual"
printf 'ok - seed-hosted-source-macros\n'
