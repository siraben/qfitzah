#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 MES_HOST MES_SOURCE" >&2
  exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixture=$root/tests/cases/mes-host-analyze.scm
env -u QFITZAH_DISABLE_ANALYSIS timeout 120s "$host" --mes "$mes" "$fixture" > "$tmp/analyzed"
QFITZAH_DISABLE_ANALYSIS=1 timeout 120s "$host" --mes "$mes" "$fixture" > "$tmp/reference"
diff -u "$root/tests/cases/mes-host-analyze.expected" "$tmp/reference"
cmp "$tmp/reference" "$tmp/analyzed"
echo 'ok - analyzed/reference Mes transformers: ellipses, vectors, hygiene, effects and errors'
