#!/usr/bin/env bash
# Fast seed-only unit tests; VM execution is checked by build-blynn-root.sh.
set -euo pipefail
if (( $# != 2 )); then echo "usage: $0 SEED RSC_COMPILER" >&2; exit 2; fi
seed=$(realpath "$1")
rsc=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/qfitzah-blynn-bridge.XXXXXX")
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "bridge artifacts: $work" >&2; fi' EXIT
bash "$root/bootstrap/build-hex0.sh" "$seed" "$rsc" "$work/hex0"
bash "$root/tests/hex0.sh" "$work/hex0/hex0"
bash "$root/bootstrap/build-singularity.sh" "$seed" "$rsc" "$work/singularity"
bash "$root/tests/singularity.sh" "$work/singularity/singularity"
