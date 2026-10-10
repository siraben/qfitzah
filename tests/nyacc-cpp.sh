#!/usr/bin/env bash
# NYACC_SOURCE must be the prepared working tree with freshly generated tables.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "usage: $0 MES_HOST MES_SOURCE NYACC_SOURCE" >&2
  exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
nyacc=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
actual=$(mktemp)
trap 'rm -f "$actual"' EXIT
timeout 120s "$host" --mes "$mes" -L "$nyacc/module" "$root/tests/cases/nyacc-cpp.scm" > "$actual"
diff -u "$root/tests/cases/nyacc-cpp.expected" "$actual"
echo 'ok - regenerated CPP parser (precedence, signed division, wide shifts, macros, short circuit)'
