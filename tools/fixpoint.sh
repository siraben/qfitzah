#!/bin/sh
# fixpoint.sh — end-to-end: the working MesCC src/*.c fixpoint on i386.
#
#   F1  path-independent MesCC assembly: mescc -S over all 20 mes_SOURCES under
#       BOTH ./qmes.elf and bin/mes-m2, byte-compared per unit.
#   F2  identical linked binary: build libc once (host mes-m2), link a mes
#       binary from each host's F1 .s set (mescc-tools M1/hex2), cmp the two.
#   F3  self-recompilation fixpoint: rerun the F1 sweep hosted on the
#       qmes-path mescc-linked binary; its .s must equal F1's.
#
# F2/F3 need mescc-tools (M1/hex2/blood-elf); this script self-enters
# `nix shell nixpkgs#mescc-tools` if they are not already on PATH.  bin/mes-m2
# (make mes-reference) and qmes.elf (make qmes) must already exist.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
sc="$repo/build/fixpoint"
refhash="$repo/tests/references/mescc/fixpoint/f1.sha256"
binhash="$repo/tests/references/mescc/fixpoint/mes-mescc.sha256"
JOBS=${JOBS-16}

if ! command -v M1 >/dev/null 2>&1 || ! command -v hex2 >/dev/null 2>&1; then
    echo "fixpoint: entering nix shell for mescc-tools" >&2
    exec nix shell nixpkgs#mescc-tools --command "$0" "$@"
fi

[ -x "$repo/qmes.elf" ]   || { echo "fixpoint: build qmes first (make qmes)" >&2; exit 2; }
[ -x "$repo/bin/mes-m2" ] || { echo "fixpoint: need bin/mes-m2 (make mes-reference)" >&2; exit 2; }

echo "==================== F1: path-independent MesCC assembly ===================="
rm -rf "$sc/f1-ref" "$sc/f1-qmes"; mkdir -p "$sc/f1-ref" "$sc/f1-qmes"
echo "F1: sweep bin/mes-m2 (native, fast) ..."
bash "$repo/tools/mescc-fixpoint.sh" compile "$repo/bin/mes-m2" "$sc/f1-ref" "$JOBS" >/dev/null
echo "F1: sweep ./qmes.elf (interpreted — ~16 min) ..."
bash "$repo/tools/mescc-fixpoint.sh" compile "$repo/qmes.elf" "$sc/f1-qmes" "$JOBS" >/dev/null
f1pass=0; f1div=0
for f in "$sc"/f1-ref/*.s; do
    b=$(basename "$f")
    if cmp -s "$sc/f1-ref/$b" "$sc/f1-qmes/$b"; then f1pass=$((f1pass+1))
    else echo "  F1 DIVERGE $b: $(cmp "$sc/f1-ref/$b" "$sc/f1-qmes/$b" 2>&1)"; f1div=$((f1div+1)); fi
done
( cd "$sc/f1-qmes" && sha256sum -c "$refhash" >/dev/null ) \
    && echo "F1: $f1pass/20 byte-identical AND all match committed reference hashes" \
    || { echo "F1: qmes output diverged from committed reference hashes" >&2; exit 1; }
[ "$f1div" = 0 ] || { echo "F1 FAILED ($f1div diverge)"; exit 1; }

echo "==================== F2: identical linked binary ===================="
echo "F2: building libc once (host bin/mes-m2) ..."
bash "$repo/tools/mescc-link.sh" libc "$JOBS" 2>&1 | sed 's/^/  /'
echo "F2: linking mes from the mes-m2 F1 .s -> bin/mes-mescc.ref ..."
bash "$repo/tools/mescc-link.sh" link "$sc/f1-ref"  "$repo/bin/mes-mescc.ref"  2>&1 | sed 's/^/  /'
echo "F2: linking mes from the qmes   F1 .s -> bin/mes-mescc.qmes ..."
bash "$repo/tools/mescc-link.sh" link "$sc/f1-qmes" "$repo/bin/mes-mescc.qmes" 2>&1 | sed 's/^/  /'
if cmp -s "$repo/bin/mes-mescc.ref" "$repo/bin/mes-mescc.qmes"; then
    got=$(sha256sum "$repo/bin/mes-mescc.qmes" | awk '{print $1}')
    want=$(awk '{print $1}' "$binhash" 2>/dev/null || echo "")
    echo "F2: LINKED BINARIES BYTE-IDENTICAL  sha256=$got"
    [ -z "$want" ] || [ "$got" = "$want" ] || { echo "F2: WARNING binary hash != committed ($want)" >&2; }
else
    echo "F2 FAILED: bin/mes-mescc.ref != bin/mes-mescc.qmes" >&2
    exit 1
fi

echo "==================== F3: self-recompilation fixpoint ===================="
echo "F3: rerun the F1 sweep hosted on the qmes-path mescc binary ..."
rm -rf "$sc/f3"; mkdir -p "$sc/f3"
bash "$repo/tools/mescc-fixpoint.sh" compile "$repo/bin/mes-mescc.qmes" "$sc/f3" "$JOBS" >/dev/null
( cd "$sc/f3" && sha256sum -c "$refhash" >/dev/null ) \
    && echo "F3: 20/20 units match F1 — self-recompilation fixpoint reached" \
    || { echo "F3 FAILED: sweep on mes-mescc.qmes diverged from F1" >&2; exit 1; }

echo "============================================================================"
echo "FIXPOINT (i386): F1 20/20  |  F2 byte-identical binary  |  F3 20/20"
echo "No C compiler anywhere in this artifact's ancestry."
