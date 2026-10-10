#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 SEED RSC_COMPILER" >&2
  exit 2
fi
seed=$(realpath "$1")
compiler=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
b=$root/bootstrap
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat "$b/rsc-prelude.scm" "$b/rsc-control.scm" "$b/rsc-ports.scm" "$root/tests/cases/rsc-ports.scm" \
  | timeout 120s "$compiler" > "$tmp/program.qfasm"
cat "$b/qfasm.qf1" "$b/runtime-support.qf1" "$b/gc.qf1" "$b/io.qf1" \
    "$b/control.qf1" "$b/lookup.qf1" "$b/rsc-runtime.qf1" "$tmp/program.qfasm" \
  | timeout 120s "$seed" > "$tmp/program"
chmod +x "$tmp/program"
(cd "$tmp" && QFITZAH_IO_TEST='environment value' timeout 30s ./program alpha 'two words') \
  > "$tmp/actual" 2> "$tmp/error"
diff -u "$root/tests/cases/rsc-ports.expected" "$tmp/actual"
printf 'stderr works\n' > "$tmp/expected-error"
diff -u "$tmp/expected-error" "$tmp/error"
[[ $(wc -c < "$tmp/roundtrip.bin") == 12345 ]]
echo 'ok - rsc-ports (binary files, string ports, argv/environment, printing)'
