#!/bin/sh
# boot-cut-gate.sh — run qmes.elf against the boot-5 cut gates B0..B11 and diff
# byte-exact stdout + stderr + exit status against the recorded mes-m2
# references (tests/references/boot-gates/, from tools/record-mes-references.sh).
#
# This is the boot-cut differential gate driver.  It presumes
# tools/make-mesroot.sh and tools/gen-boot-cuts.sh have run (so the cuts are
# linked into build/mesroot).
#
# Usage: tools/boot-cut-gate.sh [qmes.elf] [rungs...]
#   default qmes.elf; default rungs B0..B11.  MES_ARENA/MES_STACK overridable.
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
qmes=${1:-./qmes.elf}
[ $# -gt 0 ] && shift
ref=tests/references/boot-gates
rungs=${*:-B0 B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11}
: "${MES_ARENA:=20000000}"; : "${MES_STACK:=5000000}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0; total=0
for g in $rungs; do
  total=$((total+1))
  MES_BOOT="$g.scm" MES_PREFIX="$repo_root/build/mesroot" \
    MES_ARENA="$MES_ARENA" MES_MAX_ARENA="$MES_ARENA" MES_STACK="$MES_STACK" \
    LANG= LC_ALL= TZ=UTC MES_DEBUG=0 "$qmes" >"$tmp/out" 2>"$tmp/err" </dev/null
  qst=$?
  # A missing reference status/output file is a hard failure, not an empty
  # comparison that silently matches.
  if [ ! -f "$ref/$g.status" ] || [ ! -f "$ref/$g.out" ] || [ ! -f "$ref/$g.err" ]; then
    echo "$g: MISSING REFERENCE ($ref/$g.{status,out,err}) — run tools/record-mes-references.sh"
    continue
  fi
  rst=$(cat "$ref/$g.status")
  if cmp -s "$tmp/out" "$ref/$g.out" && cmp -s "$tmp/err" "$ref/$g.err" \
       && [ "$qst" = "$rst" ]; then
    echo "$g: OK (exit $qst)"; pass=$((pass+1))
  else
    echo "$g: DIFF (qmes exit=$qst ref=$rst)"
    cmp -s "$tmp/out" "$ref/$g.out" || { echo "  --- stdout diff ---"; diff "$ref/$g.out" "$tmp/out" | head -20; }
    cmp -s "$tmp/err" "$ref/$g.err" || { echo "  --- stderr diff ---"; diff "$ref/$g.err" "$tmp/err" | head -20; }
  fi
done
echo "boot-cut gate: $pass/$total"
[ "$pass" = "$total" ] || { echo "boot-cut gate: FAILED ($((total - pass)) of $total diverged)" >&2; exit 1; }
