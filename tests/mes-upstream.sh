#!/usr/bin/env bash
# Optional source integration checks; fetch pinned archives before running.
# No network access or host Scheme invocation occurs here.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "usage: $0 MES_HOST MES_SOURCE_ROOT" >&2
  exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/qfitzah-mes-upstream.XXXXXX")
trap 'status=$?; if [ "$status" -eq 0 ]; then rm -rf "$tmp"; else echo "kept $tmp" >&2; fi' EXIT
for test in mes-host-syntax mes-host-upstream mes-host-options; do
  timeout 60s "$host" --mes "$mes" -L "$root/tests/modules" "$root/tests/cases/$test.scm" > "$tmp/$test.out"
  diff -u "$root/tests/cases/$test.expected" "$tmp/$test.out"
  echo "ok - $test (pinned Mes source)"
done
bash "$root/tests/mes-host-analyze.sh" "$host" "$mes"
