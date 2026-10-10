#!/usr/bin/env bash
# Rebuild libc and TCC through boot0..boot3; require compiler/runtime fixpoints.
# Converge first with Mes helpers, then promote to TCC's complete i386 runtime.
# No host compiler, assembler, linker or ar is used.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 INITIAL_TCC_BUILD BUILT_MES_LIBC_TCC" >&2; exit 2
fi
prefix=$(realpath "$1")
mes=$(realpath "$2")/source
source=$prefix/source
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test -x "$prefix/tcc-mes"
test -f "$source/config.h"
flags=(-g -v -static -nostdinc -DBOOTSTRAP=1 -DHAVE_FLOAT=1 -DHAVE_BITFIELD=1
  -DHAVE_LONG_LONG=1 -DHAVE_SETJMP=1 -I "$source" -I "$mes/include"
  -DTCC_TARGET_I386=1 "-DCONFIG_TCCDIR=\"$prefix/lib/tcc\""
  "-DCONFIG_TCC_CRTPREFIX=\"$prefix/lib\"" '-DCONFIG_TCC_ELFINTERP="/mes/loader"'
  "-DCONFIG_TCC_LIBPATHS=\"$prefix/lib:$prefix/lib/tcc\""
  "-DCONFIG_TCC_SYSINCLUDEPATHS=\"$mes/include\""
  "-DTCC_LIBGCC=\"$prefix/lib/libc.a\"" '-DTCC_LIBTCC1="libtcc1.a"'
  -DCONFIG_TCCBOOT=1 -DCONFIG_TCC_STATIC=1 -DCONFIG_USE_LIBGCC=1
  '-DTCC_VERSION="0.9.26"' -DONE_SOURCE=1 -L "$prefix/lib" -L "$prefix/lib/tcc")
cc=$prefix/tcc-mes
bash "$b/build-tcc-libc.sh" "$cc" "$mes" "$prefix" --bootstrap-runtime
for round in 0 1 2 3; do
  next=$prefix/tcc-boot$round
  "$cc" "${flags[@]}" -o "$next" "$source/tcc.c"
  "$next" -version
  bash "$b/build-tcc-libc.sh" "$next" "$mes" "$prefix" --bootstrap-runtime
  if [[ $round == 2 ]]; then
    sha256sum "$prefix"/lib/crt*.o "$prefix"/lib/*.a "$prefix"/lib/tcc/*.a \
      "$prefix"/rebuild-libc/*.o > "$prefix/libc-fixpoint.sha256"
  fi
  cc=$next
done
cmp "$prefix/tcc-boot2" "$prefix/tcc-boot3"
sha256sum -c "$prefix/libc-fixpoint.sha256"
cp "$prefix/libc-fixpoint.sha256" "$prefix/bootstrap-libc-fixpoint.sha256"
# Bootstrap helpers truncate some wide operations. Do not ship them as the
# finished runtime, even though the bootstrap compiler itself has converged.
bash "$b/build-tcc-libc.sh" "$cc" "$mes" "$prefix"
for round in 0 1 2; do
  next=$prefix/tcc-full$round
  "$cc" "${flags[@]}" -o "$next" "$source/tcc.c"
  "$next" -version
  bash "$b/build-tcc-libc.sh" "$next" "$mes" "$prefix"
  if [[ $round == 1 ]]; then
    sha256sum "$prefix"/lib/crt*.o "$prefix"/lib/*.a "$prefix"/lib/tcc/*.a \
      "$prefix"/rebuild-libc/*.o > "$prefix/libc-fixpoint.sha256"
  fi
  cc=$next
done
cmp "$prefix/tcc-full1" "$prefix/tcc-full2"
sha256sum -c "$prefix/libc-fixpoint.sha256"
cp "$prefix/tcc-full2" "$prefix/tcc"
sha256sum "$prefix/tcc" > "$prefix/tcc.sha256"
printf 'ok - TCC and libc fixpoints: %s\n' "$prefix/tcc"
