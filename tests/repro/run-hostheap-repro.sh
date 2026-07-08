#!/bin/sh
# run-hostheap-repro.sh HOST SCRIPT [MES_DEBUG] -- load SCRIPT through the
# full module system with the mescc-smoke environment (build/mesroot must
# exist: tools/make-mesroot.sh).  tests/repro/modules is prepended to the
# load path so (test hostheap-cliff) resolves.
set -eu
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
root="$repo_root/build/mesroot"
host=$1; script=$2; dbg=${3-0}
cd "$repo_root"
exec env -i \
    PATH="$PATH" LANG= MES_DEBUG="$dbg" %version=0.27.1 \
    MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=5000000 \
    MES_PREFIX="$root" srcdest="$repo_root/third_party/mes/" \
    GUILE_LOAD_PATH="$repo_root/tests/repro/modules:$root/mes/module" \
    "$host" --no-auto-compile "$script"
