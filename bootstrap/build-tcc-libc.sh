#!/usr/bin/env bash
# Rebuild GNU Mes libc using a bootstrapped TCC, never host cc/ar.
# PREFIX is the fixed prefix embedded in that TCC. Reuse it between rounds:
# stable source paths also keep __FILE__ and debug metadata reproducible.
set -euo pipefail
if [[ $# != 3 && ( $# != 4 || ${4:-} != --bootstrap-runtime ) ]]; then
  echo "usage: $0 BOOTSTRAPPED_TCC PREPARED_MES_SOURCE PREFIX [--bootstrap-runtime]" >&2; exit 2
fi
cc=$(realpath "$1")
mes=$(realpath "$2")
prefix=$(realpath "$3")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test -f "$mes/include/mes/config.h"
work=$prefix/rebuild-libc
mkdir -p "$work" "$prefix/lib/tcc"
while IFS= read -r file; do
  case "$file" in ''|'#'*) continue;; esac
  test -f "$mes/$file"
  if [[ $file == lib/mes/abtod.c ]]; then
    # The upstream bootstrap converter loses fractional digits and wide integers.
    cat "$b/mes-libc/abtod.c"
  else
    cat "$mes/$file"
  fi
  printf '\n'
done < "$b/mes-libc/unified.sources" > "$work/unified-libc.c"
flags=(-nostdinc -DHAVE_CONFIG_H=1 -I "$mes/include" -I "$mes/include/linux/x86")
for crt in crt1 crti crtn; do
  "$cc" -c "${flags[@]}" -o "$prefix/lib/$crt.o" "$mes/lib/linux/x86-mes-gcc/$crt.c"
done
"$cc" -c "${flags[@]}" -o "$work/unified-libc.o" "$work/unified-libc.c"
"$cc" -ar cr "$prefix/lib/libc.a" "$work/unified-libc.o"
if [[ ${4:-} == --bootstrap-runtime ]]; then
  # Mes's deliberately limited helpers suffice to reach a converged compiler.
  "$cc" -c "${flags[@]}" -DHAVE_LONG_LONG=1 -DHAVE_FLOAT=1 \
    -o "$work/libtcc1.o" "$mes/lib/libtcc1.c"
  "$cc" -ar cr "$prefix/lib/tcc/libtcc1.a" "$work/libtcc1.o"
else
  # Use that compiler's own C compiler, assembler and archiver for the complete
  # i386 arithmetic/conversion/stack helpers. No host tools or prebuilt objects.
  runtime=$prefix/source/lib
  objects=()
  for source in libtcc1.c alloca86.S alloca86-bt.S; do
    test -f "$runtime/$source"
    object=$work/${source%.*}.o
    "$cc" -c "${flags[@]}" -DTCC_TARGET_I386=1 -o "$object" "$runtime/$source"
    objects+=("$object")
  done
  "$cc" -ar cr "$prefix/lib/tcc/libtcc1.a" "${objects[@]}"
fi
"$cc" -c "${flags[@]}" -o "$work/getopt.o" "$mes/lib/posix/getopt.c"
"$cc" -ar cr "$prefix/lib/libgetopt.a" "$work/getopt.o"
printf 'rebuilt libc with %s\n' "$cc"
