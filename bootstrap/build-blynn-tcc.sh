#!/usr/bin/env bash
# HCC -> TinyCC -> native self-rebuild, using only source-built tools.
set -euo pipefail
if (( $# != 4 )); then
  echo "usage: $0 QFITZAH_TOOLS BLYNN_HCC SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
tools=$(realpath "$1")
hcc=$(realpath "$2")
cache=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$4"
out=$(realpath "$4")
mkdir "$out/recipe" "$out/tmp"
cp -RL "$root/bootstrap" "$root/tests" "$out/recipe/"
b=$out/recipe/bootstrap
sha256sum -c "$tools/tools.sha256"
sha256sum -c "$hcc/hcc.sha256"
bash "$b/prepare-blynn-tcc.sh" "$cache" "$out/prepared"
target=$out/prepared/target
(cd "$target" && patch --batch --fuzz=0 -p1 < "$b/blynn/patches/tcc-relative-include.patch")
export PATH="$tools/bin:$PATH" TMPDIR="$out/tmp"
export BOOTSTRAP_LIB="$target/scripts/lib/bootstrap.sh"
export TINYCC_DIR="$out/prepared/tinycc" HCC_BIN_DIR="$hcc/hcc"
export MES_LIBC_DIR="$out/prepared/libc" M2LIBC_PATH="$tools/stage0/M2libc"
export HCC_SUPPORT_DIR="$target/hcc/support" HCC_TARGET=amd64 TINYCC_SELFHOST=1
OUT_DIR="$out/tcc" sh "$target/scripts/tinycc-boot-hcc.sh"
sha256sum "$out/tcc/bin/"* "$out/tcc/lib/"* > "$out/bootstrap-tcc.sha256"
bash "$b/finalize-blynn-tcc.sh" "$out/tcc" "$out/prepared" "$out/final"
sha256sum "$out/final/bin/tcc" "$out/final/lib/"* > "$out/tcc.sha256"
echo 'ok - HCC-built TinyCC and native compiler/runtime fixpoints with C/numeric probes'
