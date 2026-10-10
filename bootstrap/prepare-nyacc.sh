#!/usr/bin/env bash
# Copy verified upstream source, deliberately dropping distributed parser tables.
# Generation must happen using the source-built Mes host, not a host Guile.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 NYACC_SOURCE NEW_DIRECTORY" >&2
  exit 2
fi
source=$(realpath "$1")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for generator in gen-cpp-files.scm gen-c99-files.scm gen-c99cx-files.scm; do
  test -f "$source/$generator"
done
mkdir -- "$2"
out=$(realpath "$2")
# Dereference source-tree links so cleaning cannot follow links back upstream.
cp -RL "$source/." "$out/"
for grammar in cpp c99 c99x c99cx; do
  for kind in act tab; do
    rm -f -- "$out/module/nyacc/lang/c99/mach.d/$grammar-$kind.scm"
  done
done
# Mes normally ignores these legacy Guile imports. Our lexical module host
# needs the explicit modern interfaces instead of Guile 1.8's syncase shim.
patch --batch --forward --fuzz=0 -d "$out" -p1 < "$b/upstream/patches/nyacc-mes-modules.patch" >&2
printf '%s\n' "$out"
