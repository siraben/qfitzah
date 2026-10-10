#!/usr/bin/env bash
# TINY_SEED is built with SEED_CELL_BYTES=262144 and SEED_GC_TRACE=1.
# Requires only the seed and file utilities, not a host compiler at test time.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "usage: $0 TINY_SEED" >&2
  exit 2
fi
seed=$(realpath "$1")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ulimit -c 0
{
  printf '(Rule (Expand x) (Answer x x x x))\n'
  for ((i=0; i<10000; i++)); do printf '(Expand A)\n'; done
  printf '(Rule (Expand x) (New x))\n(Expand A)\n'
} > "$tmp/input"
{
  for ((i=0; i<10000; i++)); do printf '(Answer A A A A)\n'; done
  printf '(New A)\n'
} > "$tmp/expected"
timeout 30s "$seed" < "$tmp/input" > "$tmp/actual" 2> "$tmp/trace"
diff -u "$tmp/expected" "$tmp/actual"
grep -Eq '^G+$' "$tmp/trace"
echo 'ok - seed-gc (reclaimed cells, persistent rules, memo invalidation)'

# All these rules remain reachable from the atom table. Exhaustion must be
# diagnosed without a crash, silently dropping rules, or following free cells.
for ((i=0; i<10000; i++)); do printf '(Rule (Keep %s) (Held %s))\n' "$i" "$i"; done > "$tmp/input"
status=0
timeout 30s "$seed" < "$tmp/input" > "$tmp/actual" 2> "$tmp/trace" || status=$?
[[ $status == 1 && ! -s "$tmp/actual" ]]
grep -Eq '^G*qfitzah: out of memory$' "$tmp/trace"
echo 'ok - seed-gc live exhaustion is diagnosed'
