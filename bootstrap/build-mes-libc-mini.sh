#!/usr/bin/env bash
# Compatibility entry for the independently testable first libc milestone.
set -euo pipefail
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$b/build-mes-libc.sh" mini "$@"
