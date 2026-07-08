#!/bin/sh
# boot-cut-gate.sh — run qmes.elf against the boot-5 cut gates B0..B2 and diff
# byte-exact stdout + exit status against the recorded mes-m2 references
# (tests/mes-references/, produced by tools/record-mes-references.sh).
#
# This is the S1 gate driver.  It presumes tools/make-mesroot.sh and
# tools/gen-boot-cuts.sh have run (so the cuts are linked into build/mesroot).
#
# Usage: tools/boot-cut-gate.sh [qmes.elf]   (default ./qmes.elf)
set -u
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
qmes=${1:-./qmes.elf}
ref=tests/mes-references

pass=0; total=0
for g in B0 B1 B2; do
  total=$((total+1))
  # qmes output is arena-size-independent pre-GC, so use modest sizes for speed.
  qout=$(MES_BOOT="$g.scm" MES_PREFIX="$repo_root/build/mesroot" \
         MES_ARENA=2000000 MES_STACK=200000 \
         LANG= LC_ALL= TZ=UTC MES_DEBUG=0 "$qmes" 2>/dev/null </dev/null)
  qst=$?
  rout=$(cat "$ref/$g.out" 2>/dev/null)
  rst=$(cat "$ref/$g.status" 2>/dev/null)
  if [ "$qout" = "$rout" ] && [ "$qst" = "$rst" ]; then
    echo "$g: OK (exit $qst)"; pass=$((pass+1))
  else
    echo "$g: DIFF  qmes(exit=$qst)=[$qout]  ref(exit=$rst)=[$rout]"
  fi
done
echo "boot-cut gate: $pass/$total"
