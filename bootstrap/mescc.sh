#!/usr/bin/env bash
# Invoke pinned MesCC source through the bootstrapped host, in M1-output mode.
set -euo pipefail
if (( $# < 4 )); then
  echo "usage: $0 MES_HOST MES_SOURCE GENERATED_NYACC -S [MESCC_ARGUMENT ...]" >&2
  exit 2
fi
host=$(realpath "$1")
mes=$(realpath "$2")
nyacc=$(realpath "$3")
shift 3
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -n ${QFITZAH_MESCC_NORMALIZER:-} && -z ${QFITZAH_MESCC_NATIVE_PHASE:-} && -z ${QFITZAH_MESCC_RAW_AST_OUTPUT:-} ]]; then
  exec bash "$root/bootstrap/mescc-native.sh" "$QFITZAH_MESCC_NORMALIZER" "$host" "$mes" "$nyacc" "$@"
fi
exec env "%prefix=$mes" "%includedir=$mes/include" \
  "$host" --mes "$mes" -L "$nyacc/module" "$root/bootstrap/mescc.scm" -- "$@"
