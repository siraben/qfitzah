#!/usr/bin/env bash
# Differential sweep of qmes.elf vs bin/mes-m2 over all scaffold/boot files.
set -u
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pfx=$repo/third_party/mes
qmes=$repo/qmes.elf
mesm2=$repo/bin/mes-m2
match=0; total=0
printf '%-28s %6s %6s %s\n' FILE qmes mesm2 result
for f in "$pfx"/scaffold/boot/*.scm; do
  t=$(basename "$f" .scm)
  MES_BOOT=$f MES_PREFIX=$pfx "$qmes" >/dev/null 2>&1; q=$?
  MES_BOOT=$f MES_PREFIX=$pfx MES_ARENA=20000000 MES_STACK=5000000 LANG= MES_DEBUG=0 "$mesm2" >/dev/null 2>&1; m=$?
  total=$((total+1))
  if [ "$q" = "$m" ]; then r=ok; match=$((match+1)); else r=DIFF; fi
  printf '%-28s %6s %6s %s\n' "$t" "$q" "$m" "$r"
done
echo "match: $match/$total"
