#!/usr/bin/env bash
# Source frontend -> source-built native Mes normalization -> source backend.
set -euo pipefail
if (( $# < 5 )); then
  echo "usage: $0 NORMALIZER HOST MES_SOURCE GENERATED_NYACC -S [ARGUMENT ...]" >&2
  exit 2
fi
normalizer=$(realpath -e "$1")
host=$2
mes=$3
nyacc=$4
shift 4
test -x "$normalizer"
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d /tmp/qfitzah-native-mescc.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "native MesCC artifacts: $work" >&2; fi' EXIT
QFITZAH_MESCC_NATIVE_PHASE=frontend QFITZAH_MESCC_RAW_AST_OUTPUT="$work/input.raw" \
QFITZAH_MESCC_NATIVE_BYPASS="$work/bypass" \
  bash "$b/mescc.sh" "$host" "$mes" "$nyacc" "$@"
if [[ -f $work/bypass ]]; then
  grep -qx qfitzah-mescc-native-bypass-v1 "$work/bypass"
  test ! -e "$work/input.raw.complete"
  exit 0
fi
grep -qx qfitzah-mescc-raw-ast-v1 "$work/input.raw.complete"
normalized=${QFITZAH_MESCC_AST_OUTPUT:-$work/input.E}
test ! -e "$normalized"
test ! -e "$normalized.complete"
"$normalizer" < "$work/input.raw" > "$normalized"
test -s "$normalized"
printf 'qfitzah-mescc-ast-v1\n' > "$normalized.complete"
QFITZAH_MESCC_NATIVE_PHASE=backend QFITZAH_MESCC_NORMALIZED_AST="$normalized" \
  bash "$b/mescc.sh" "$host" "$mes" "$nyacc" "$@"
