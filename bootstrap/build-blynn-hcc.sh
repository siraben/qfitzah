#!/usr/bin/env bash
# Pinned modern Blynn compiler -> HCC, with the source-built M2 backend only.
set -euo pipefail
if (( $# != 4 )); then
  echo "usage: $0 QFITZAH_TOOLS BLYNN_ROOT SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
tools=$(realpath "$1")
old=$(realpath "$2")
cache=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$4"
out=$(realpath "$4")
mkdir "$out/recipe" "$out/tmp"
cp -RL "$root/bootstrap" "$out/recipe/"
b=$out/recipe/bootstrap
sha256sum -c "$tools/tools.sha256"
sha256sum -c "$old/root.sha256"
bash "$b/blynn/export-source.sh" "$cache" blynn-bootstrap "$out/target"
bash "$b/blynn/export-source.sh" "$cache" blynn-compiler "$out/source"
target=$out/target
# Repair stale/asymmetric patch context, not the intended code changes.
for context in local-patch-context runtime-patch-context; do
  (cd "$target" && patch --batch --fuzz=0 -p1 < "$b/blynn/patches/$context.patch")
done
while IFS= read -r patch; do
  [[ -n $patch ]] || continue
  file=$target/patches/upstreams/$patch
  if [[ $patch == blynn-compiler-crossly-perf.patch ]]; then
    file=$b/blynn/patches/crossly-perf-context.patch
  fi
  (cd "$out/source" && patch --batch --fuzz=0 -p1 < "$file")
done < "$target/patches/upstreams/blynn-compiler.series"
export PATH="$tools/bin:$PATH" TMPDIR="$out/tmp"
export M2LIBC_PATH="$tools/stage0/M2libc" M2_ARCH=amd64 M2_OS=Linux
export M2_MESOPLANET="$tools/bin/M2-Mesoplanet"
export BOOTSTRAP_LIB="$target/scripts/lib/bootstrap.sh"
export BLYNN_DIR="$out/source" METHODICALLY="$old/bin/methodically"
export CROSSLY_TOP=134217728 PRECISELY_TOP=33554432
OUT_DIR="$out/precisely" sh "$target/scripts/bootstrap-blynn-precisely.sh"
export HCC_DIR="$target/hcc" BLYNN_COMPILER="$out/precisely/bin/crossly1"
unset HCPP_MODULES HCC1_MODULES HCC_COMMON_MODULES
OUT_DIR="$out/sources" sh "$target/scripts/hcc-blynn-sources.sh"
export HCC_BLYNN_SOURCES_DIR="$out/sources"
mkdir "$out/objects"
export MATERIALIZE_OBJECT_SCRIPT="$out/objects/materialize-object-script"
"$M2_MESOPLANET" --operating-system Linux --architecture amd64 \
  -f "$target/hcc/support/materialize-object-script.c" -o "$MATERIALIZE_OBJECT_SCRIPT"
chmod 555 "$MATERIALIZE_OBJECT_SCRIPT"
OUT_DIR="$out/objects" sh "$target/scripts/hcc-blynn-objs.sh"
export HCC_BLYNN_OBJECTS_DIR="$out/objects" HCPP_TOP=134217728 HCC1_TOP=134217728
OUT_DIR="$out/c" sh "$target/scripts/hcc-blynn-c.sh"
export HCC_BLYNN_C_DIR="$out/c" HCC_C_BACKEND=m2
unset HCC_RTS_ADAPTIVE_MAJOR_WORDS
OUT_DIR="$out/hcc" sh "$target/scripts/hcc-blynn-bin.sh"
sha256sum "$out/precisely/bin/"* "$out/hcc/bin/"* > "$out/hcc.sha256"
echo 'ok - source-built Blynn/precisely and HCC through M2 only'
