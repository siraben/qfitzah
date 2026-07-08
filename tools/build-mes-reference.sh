#!/bin/sh
# build-mes-reference.sh — Build the reference GNU Mes interpreter (bin/mes-m2)
# via the traditional hex/M2-Planet path, for use as the differential-testing
# baseline in the Mes bootstrap (P0).
#
# It transcribes third_party/mes/kaem.run (the M2-Planet -> blood-elf -> M1 ->
# hex2 sequence) using nixpkgs' m2-planet (1.13.1) and mescc-tools (1.7.0).
#
# Usage:
#   nix shell nixpkgs#m2-planet nixpkgs#mescc-tools --command tools/build-mes-reference.sh
# or simply:
#   tools/build-mes-reference.sh          # self-enters the nix shell if needed
#
# Output: bin/mes-m2  (base-address 0x1000000 i386 ELF)
# Intermediates + generated config.h live under build/mes-reference/.
#
# Determinism: MES_VERSION pinned to the tree's VERSION (0.27.1), LANG cleared,
# fixed architecture (x86/i386). No host cc/as/ld used.

set -eu

# Re-exec inside a nix shell that provides M2-Planet, M1, hex2, blood-elf if the
# tools are not already on PATH.
if ! command -v M2-Planet >/dev/null 2>&1 || ! command -v hex2 >/dev/null 2>&1; then
    echo "build-mes-reference: entering nix shell for m2-planet + mescc-tools" >&2
    exec nix shell nixpkgs#m2-planet nixpkgs#mescc-tools --command "$0" "$@"
fi

LANG=
export LANG

# Resolve repo root from this script's location (tools/..).
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/.." && pwd)

MES=$root/third_party/mes
srcdest=$MES/          # kaem.run convention: trailing slash
BUILD=$root/build/mes-reference
BIN=$root/bin

# CPU/arch settings.  ARCH=x86 (default, from kaem.x86) or ARCH=x86_64 (kaem.x86_64).
ARCH=${ARCH:-x86}
case "$ARCH" in
  x86)
    cc_cpu=i386;    mes_cpu=x86;     stage0_cpu=x86;   blood_elf_flag=--little-endian; out_name=mes-m2 ;;
  x86_64)
    cc_cpu=x86_64;  mes_cpu=x86_64;  stage0_cpu=amd64; blood_elf_flag=--64; out_name=mes-m2-64 ;;
  *) echo "build-mes-reference: unknown ARCH=$ARCH (want x86 or x86_64)" >&2; exit 2 ;;
esac

# Version pinned from the tree (configure.sh: VERSION=...).
VERSION=$(sed -n 's/^VERSION=//p' "$MES/configure.sh" | head -1)
: "${VERSION:?could not read VERSION from configure.sh}"
echo "build-mes-reference: MES_VERSION=$VERSION" >&2

rm -rf "$BUILD"
mkdir -p "$BUILD/m2" "$BIN"

# --- Generate include/mes/config.h (per configure.sh lines 253-265, non-system
#     libc path used by the M2 build). ---
config_h=$BUILD/config.h
{
    echo '#undef SYSTEM_LIBC'
    echo "#define MES_VERSION \"$VERSION\""
} > "$config_h"

# --- Step 1: M2-Planet compiles config.h + lib/ support units + src/*.c to
#     m2/mes.M1.  Identical file list to kaem.run:30-144, with config.h swapped
#     for our generated copy so the submodule tree stays untouched. ---
echo "build-mes-reference: M2-Planet -> m2/mes.M1" >&2
M2-Planet                                               \
    --debug                                             \
    --architecture ${stage0_cpu}                        \
    -D __${cc_cpu}__=1                                  \
    -D __linux__=1                                      \
    -f "$config_h"                                       \
    -f ${srcdest}include/mes/lib-mini.h                 \
    -f ${srcdest}include/mes/lib.h                       \
    -f ${srcdest}lib/linux/${mes_cpu}-mes-m2/crt1.c      \
    -f ${srcdest}lib/mes/__init_io.c                     \
    -f ${srcdest}lib/linux/${mes_cpu}-mes-m2/_exit.c     \
    -f ${srcdest}lib/linux/${mes_cpu}-mes-m2/_write.c    \
    -f ${srcdest}lib/mes/globals.c                       \
    -f ${srcdest}lib/m2/cast.c                           \
    -f ${srcdest}lib/stdlib/exit.c                       \
    -f ${srcdest}lib/mes/write.c                         \
    -f ${srcdest}include/linux/${mes_cpu}/syscall.h      \
    -f ${srcdest}lib/linux/${mes_cpu}-mes-m2/syscall.c   \
    -f ${srcdest}lib/stub/__raise.c                      \
    -f ${srcdest}lib/linux/brk.c                         \
    -f ${srcdest}lib/linux/malloc.c                      \
    -f ${srcdest}lib/string/memset.c                     \
    -f ${srcdest}lib/linux/read.c                        \
    -f ${srcdest}lib/mes/fdgetc.c                        \
    -f ${srcdest}lib/stdio/getchar.c                     \
    -f ${srcdest}lib/stdio/putchar.c                     \
    -f ${srcdest}lib/stub/__buffered_read.c              \
    -f ${srcdest}include/errno.h                         \
    -f ${srcdest}include/fcntl.h                         \
    -f ${srcdest}lib/linux/_open3.c                      \
    -f ${srcdest}lib/linux/open.c                        \
    -f ${srcdest}lib/mes/mes_open.c                      \
    -f ${srcdest}lib/string/strlen.c                     \
    -f ${srcdest}lib/mes/eputs.c                         \
    -f ${srcdest}lib/mes/fdputc.c                        \
    -f ${srcdest}lib/mes/eputc.c                         \
    -f ${srcdest}include/time.h                          \
    -f ${srcdest}include/sys/time.h                      \
    -f ${srcdest}include/m2/types.h                      \
    -f ${srcdest}include/sys/types.h                     \
    -f ${srcdest}include/sys/utsname.h                   \
    -f ${srcdest}include/mes/mes.h                       \
    -f ${srcdest}include/mes/builtins.h                  \
    -f ${srcdest}include/mes/constants.h                 \
    -f ${srcdest}include/mes/symbols.h                   \
    -f ${srcdest}lib/mes/__assert_fail.c                 \
    -f ${srcdest}lib/mes/assert_msg.c                    \
    -f ${srcdest}lib/mes/fdputc.c                        \
    -f ${srcdest}lib/string/strncmp.c                    \
    -f ${srcdest}lib/posix/getenv.c                      \
    -f ${srcdest}lib/mes/fdputs.c                        \
    -f ${srcdest}lib/mes/ntoab.c                         \
    -f ${srcdest}lib/ctype/isdigit.c                     \
    -f ${srcdest}lib/ctype/isxdigit.c                    \
    -f ${srcdest}lib/ctype/isspace.c                     \
    -f ${srcdest}lib/ctype/isnumber.c                    \
    -f ${srcdest}lib/mes/abtol.c                         \
    -f ${srcdest}lib/stdlib/atoi.c                       \
    -f ${srcdest}lib/string/memcpy.c                     \
    -f ${srcdest}lib/stdlib/free.c                       \
    -f ${srcdest}lib/stdlib/realloc.c                    \
    -f ${srcdest}lib/string/strcpy.c                     \
    -f ${srcdest}lib/mes/itoa.c                          \
    -f ${srcdest}lib/mes/ltoa.c                          \
    -f ${srcdest}lib/mes/fdungetc.c                      \
    -f ${srcdest}lib/posix/setenv.c                      \
    -f ${srcdest}lib/linux/access.c                      \
    -f ${srcdest}include/linux/m2/kernel-stat.h          \
    -f ${srcdest}include/sys/stat.h                      \
    -f ${srcdest}lib/linux/chmod.c                       \
    -f ${srcdest}lib/linux/ioctl3.c                      \
    -f ${srcdest}include/sys/ioctl.h                     \
    -f ${srcdest}lib/m2/isatty.c                         \
    -f ${srcdest}include/signal.h                        \
    -f ${srcdest}lib/linux/fork.c                        \
    -f ${srcdest}lib/m2/execve.c                         \
    -f ${srcdest}lib/m2/execv.c                          \
    -f ${srcdest}include/sys/resource.h                  \
    -f ${srcdest}lib/linux/wait4.c                       \
    -f ${srcdest}lib/linux/waitpid.c                     \
    -f ${srcdest}lib/linux/gettimeofday.c                \
    -f ${srcdest}lib/linux/clock_gettime.c               \
    -f ${srcdest}lib/m2/time.c                           \
    -f ${srcdest}lib/linux/_getcwd.c                     \
    -f ${srcdest}include/limits.h                        \
    -f ${srcdest}lib/m2/getcwd.c                         \
    -f ${srcdest}lib/linux/dup.c                         \
    -f ${srcdest}lib/linux/dup2.c                        \
    -f ${srcdest}lib/string/strcmp.c                     \
    -f ${srcdest}lib/string/memcmp.c                     \
    -f ${srcdest}lib/linux/uname.c                       \
    -f ${srcdest}lib/linux/unlink.c                      \
    -f ${srcdest}src/builtins.c                          \
    -f ${srcdest}src/core.c                              \
    -f ${srcdest}src/display.c                           \
    -f ${srcdest}src/eval-apply.c                        \
    -f ${srcdest}src/gc.c                                \
    -f ${srcdest}src/hash.c                              \
    -f ${srcdest}src/lib.c                               \
    -f ${srcdest}src/m2.c                                \
    -f ${srcdest}src/math.c                              \
    -f ${srcdest}src/mes.c                               \
    -f ${srcdest}src/module.c                            \
    -f ${srcdest}src/posix.c                             \
    -f ${srcdest}src/reader.c                            \
    -f ${srcdest}src/stack.c                             \
    -f ${srcdest}src/string.c                            \
    -f ${srcdest}src/struct.c                            \
    -f ${srcdest}src/symbol.c                            \
    -f ${srcdest}src/variable.c                          \
    -f ${srcdest}src/vector.c                            \
    -o "$BUILD/m2/mes.M1"

# --- Step 2: blood-elf adds ELF debug stubs. ---
echo "build-mes-reference: blood-elf" >&2
blood-elf ${blood_elf_flag} --little-endian -f "$BUILD/m2/mes.M1" -o "$BUILD/m2/mes.blood-elf-M1"

# --- Step 3: M1 assembles to hex2. ---
echo "build-mes-reference: M1 -> m2/mes.hex2" >&2
M1                                                      \
    --architecture ${stage0_cpu}                        \
    --little-endian                                     \
    -f ${srcdest}lib/m2/${mes_cpu}/${mes_cpu}_defs.M1   \
    -f ${srcdest}lib/${mes_cpu}-mes/${mes_cpu}.M1       \
    -f ${srcdest}lib/linux/${mes_cpu}-mes-m2/crt1.M1    \
    -f "$BUILD/m2/mes.M1"                                \
    -f "$BUILD/m2/mes.blood-elf-M1"                      \
    -o "$BUILD/m2/mes.hex2"

# --- Step 4: hex2 links at base 0x1000000 -> bin/mes-m2. ---
echo "build-mes-reference: hex2 -> bin/mes-m2" >&2
hex2                                                    \
    --architecture ${stage0_cpu}                        \
    --little-endian                                     \
    --base-address 0x1000000                            \
    -f ${srcdest}lib/m2/${mes_cpu}/ELF-${mes_cpu}.hex2  \
    -f "$BUILD/m2/mes.hex2"                              \
    -o "$BIN/$out_name"

chmod +x "$BIN/$out_name"
echo "build-mes-reference: wrote $BIN/$out_name" >&2

# Smoke test (kaem.run:169).
echo "build-mes-reference: smoke test" >&2
GUILE_LOAD_PATH=${srcdest}mes/module:${srcdest}module \
    "$BIN/$out_name" -c "(display 'Hello,M2-mes!) (newline)" || {
        echo "build-mes-reference: WARNING smoke test failed" >&2
    }

echo "build-mes-reference: done" >&2
