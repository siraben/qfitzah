#!/usr/bin/env bash
# First TCC: MesCC source -> M1 -> static i386 ELF with source-built Mes libc.
# This is not the later libc rebuild/TCC self-rebuild milestone.
set -euo pipefail
if [[ $# != 7 && ( $# != 8 || ${8:-} != --from-ast ) ]]; then
  echo "usage: $0 MES_HOST M1_LINK MES_SOURCE GENERATED_NYACC TCC_SOURCE BUILT_LIBC_TCC DIRECTORY [--from-ast]" >&2
  exit 2
fi
host=$(realpath "$1")
link=$(realpath "$2")
mes=$(realpath "$3")
nyacc=$(realpath "$4")
tcc=$(realpath "$5")
libc=$(realpath "$6")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test -s "$libc/libc+tcc.M1"
if [[ ${8:-} == --from-ast ]]; then
  out=$(realpath -e "$7")
  test -s "$out/tcc.E"
  grep -qx 'qfitzah-mescc-ast-v1' "$out/tcc.E.complete"
  test -s "$out/source/tcc.c"
  # Do not overwrite a previous assembly result; linking can be retried alone.
  test ! -e "$out/tcc.M1"
  input=$out/tcc.E
else
  mkdir -- "$7"
  out=$(realpath "$7")
  bash "$b/prepare-tcc.sh" "$tcc" "$out/source" > /dev/null
  input=$out/source/tcc.c
fi
# Match live-bootstrap's i386 MesCC pass. Later TCC passes enable wider types.
flags=(-DBOOTSTRAP=1 -DHAVE_LONG_LONG=0 -DTCC_TARGET_I386=1 -Dinline=
  "-DCONFIG_TCCDIR=\"$out/lib/tcc\"" '-DCONFIG_SYSROOT="/"'
  "-DCONFIG_TCC_CRTPREFIX=\"$out/lib\"" '-DCONFIG_TCC_ELFINTERP="/mes/loader"'
  "-DCONFIG_TCC_SYSINCLUDEPATHS=\"$libc/source/include\""
  "-DTCC_LIBGCC=\"$out/lib/libc.a\"" -DCONFIG_TCC_LIBTCC1_MES=0
  -DCONFIG_TCCBOOT=1 -DCONFIG_TCC_STATIC=1 -DCONFIG_USE_LIBGCC=1
  '-DTCC_VERSION="0.9.26"' -DONE_SOURCE=1)
# Preserve the source-generated AST before backend work; never reuse a partial
# checkpoint (tcc.E.complete is written only after the AST port closes).
QFITZAH_MESCC_TRACE=1 QFITZAH_MESCC_HEAP_TRACE=1 \
QFITZAH_MESCC_AST_OUTPUT="$out/tcc.E" \
bash "$b/mescc.sh" "$host" "$libc/source" "$nyacc" \
  -S --arch x86 -m32 -I "$out/source" -I "$libc/source/include" \
  "${flags[@]}" -o "$out/tcc.M1" "$input"
"$link" --architecture x86 --little-endian --base-address 0x08048000 \
  -f "$mes/lib/x86-mes/x86.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-header.hex2" \
  -f "$libc/libc+tcc.M1" -f "$out/tcc.M1" \
  -f "$mes/lib/linux/x86-mes/elf32-footer-single-main.hex2" -o "$out/tcc-mes"
chmod +x "$out/tcc-mes"
"$out/tcc-mes" -version
printf '%s\n' "$out/tcc-mes"
