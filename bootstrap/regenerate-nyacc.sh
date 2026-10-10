#!/usr/bin/env bash
# Rebuild all parser artifacts from grammar sources, never from shipped tables.
set -euo pipefail
if [[ $# != 4 ]]; then
  echo "usage: $0 MES_HOST MES_SOURCE NYACC_SOURCE NEW_DIRECTORY" >&2; exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
source=$(realpath "$3")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=$(bash "$b/prepare-nyacc.sh" "$source" "$4")
cd "$out"
for generator in gen-cpp-files.scm gen-c99-files.scm gen-c99cx-files.scm; do
  echo "generating: $generator" >&2
  "$host" --mes "$mes" -L module "$b/nyacc-profile.scm" -- "$generator"
done
for grammar in cpp c99 c99x c99cx; do
  for kind in act tab; do
    test -s "module/nyacc/lang/c99/mach.d/$grammar-$kind.scm"
  done
done
sha256sum module/nyacc/lang/c99/mach.d/{cpp,c99,c99x,c99cx}-{act,tab}.scm
