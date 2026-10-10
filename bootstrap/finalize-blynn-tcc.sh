#!/usr/bin/env bash
# Replace bootstrap conversion helpers, then converge the native compiler AND
# its complete bootstrap libc/libtcc1 runtime. Inputs already descend from HCC.
set -euo pipefail
if (( $# != 3 )); then
  echo "usage: $0 HCC_TCC_TREE PREPARED_SOURCES NEW_DIRECTORY" >&2; exit 2
fi
initial=$(realpath "$1")
prepared=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$3"
out=$(realpath "$3")
mkdir "$out/tmp"
export TMPDIR="$out/tmp"
test -x "$initial/bin/tcc"
cmp "$initial/bin/tcc-stage2" "$initial/bin/tcc"
sha256sum "$initial/bin/tcc" > "$out/input-compiler.sha256"
cp -R "$prepared/tinycc" "$out/source"
cp "$initial/artifact/config.h" "$out/source/config.h"
(cd "$out/source" && patch --batch --fuzz=0 -p1 < "$root/bootstrap/blynn/patches/tcc-driver-errors.patch")
# Compile the decimal-conversion repair from source and preserve its license.
cp "$root/bootstrap/blynn/libc/COPYING" "$out/COPYING"
mkdir "$out/licenses"
cp "$prepared/tinycc/COPYING" "$out/licenses/TinyCC-COPYING"
cp "$prepared/mes/COPYING" "$out/licenses/GNU-Mes-COPYING"
cp "$prepared/target/LICENSE" "$out/licenses/Blynn-bootstrap-LICENSE"
cat "$root/bootstrap/blynn/libc/abtod.c" > "$out/conversion.c"
for name in strtod strtof strtold; do
  cat "$prepared/mes/lib/stdlib/$name.c" >> "$out/conversion.c"
done
target=$prepared/target
# Remove the heap-based alloca only in the native runtime. TinyCC's own
# alloca.S is linked instead; never rely on duplicate-definition selection.
mkdir -p "$out/native-prep/scripts/lib"
cp "$target/scripts/prepare-mes-libc.sh" "$out/native-prep/scripts/"
cp "$target/scripts/lib/bootstrap.sh" "$out/native-prep/scripts/lib/"
(cd "$out/native-prep" && patch --batch --fuzz=0 -p1 < "$root/bootstrap/blynn/patches/native-libc-alloca.patch")
GNU_MES_DIR="$prepared/mes" MES_LIBC_ARCH=x86_64 OUT_DIR="$out/mes-libc" \
BOOTSTRAP_LIB="$target/scripts/lib/bootstrap.sh" \
MES_STRTOD_SOURCE="$out/conversion.c" \
MES_LDEXP_SOURCE="$target/nix/sources/mes-libc/ldexp-ldexpl.c" \
MES_SETJMP_SOURCE="$target/nix/sources/mes-libc/x86_64-setjmp.c" \
MES_CONFIG_SOURCE="$target/nix/sources/mes-libc/config.h" \
  sh "$out/native-prep/scripts/prepare-mes-libc.sh"
# Relative source names keep __FILE__ and symbol-table filenames independent
# of the build directory. Every header comes from these prepared sources.
ln -s ../mes-libc "$out/source/mes-libc"
cd "$out/source"
flags=(-nostdinc -I . -I include -I mes-libc/include)
build_libraries() {
  local cc=$1 dest=$2 obj
  mkdir "$dest"
  for obj in crt1 crti crtn libc libgetopt; do
    "$cc" "${flags[@]}" -c -std=c11 -o "$dest/$obj.o" "mes-libc/lib/$obj.c"
  done
  "$cc" "${flags[@]}" -c -D TCC_TARGET_X86_64=1 -o "$dest/libtcc1.o" lib/libtcc1.c
  "$cc" "${flags[@]}" -c -o "$dest/alloca.o" lib/alloca.S
  "$cc" -ar cr "$dest/libc.a" "$dest/libc.o"
  "$cc" -ar cr "$dest/libgetopt.a" "$dest/libgetopt.o"
  "$cc" -ar cr "$dest/libtcc1.a" "$dest/libtcc1.o" "$dest/alloca.o"
}
build_compiler() {
  local cc=$1 libs=$2 output=$3
  "$cc" "${flags[@]}" -nostdlib "$libs/crt1.o" "$libs/crti.o" tcc.c \
    "$libs/libc.o" "$libs/libtcc1.o" "$libs/alloca.o" "$libs/crtn.o" -o "$output"
  test "$("./$output" -dumpversion)" = '0.9.28-unstable-2025-12-03'
}
previous=$initial/bin/tcc
for round in a b c; do
  echo "native runtime/compiler round: $round"
  build_libraries "$previous" "runtime-$round"
  build_compiler "$previous" "runtime-$round" "tcc-$round"
  previous=$out/source/tcc-$round
done
cmp tcc-b tcc-c
for artifact in runtime-b/*; do cmp "$artifact" "runtime-c/${artifact##*/}"; done
mkdir "$out/bin" "$out/lib" "$out/include"
cp tcc-c "$out/bin/tcc"
chmod 555 "$out/bin/tcc"
cp runtime-c/crt1.o runtime-c/crti.o runtime-c/crtn.o runtime-c/*.a "$out/lib/"
cp -R mes-libc/include/. "$out/include/"
cp -R include/. "$out/include/"
bash "$root/tests/tcc.sh" "$out/bin/tcc" -B "$out/lib" -DQFITZAH_POINTER_BYTES=8
sha256sum tcc-b tcc-c runtime-b/* runtime-c/* > "$out/fixpoints.sha256"
sha256sum "$out/bin/tcc" "$out/lib/"* > "$out/runtime.sha256"
echo 'ok - native TCC/compiler and complete bootstrap runtime fixpoints, C/numeric tests'
