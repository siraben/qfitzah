#!/usr/bin/env bash
# mescc-link.sh — F2/F3 support: build a runnable `mes` binary the MesCC way
# (NOT M2-Planet), harness-driven so the interpreter under test (qmes) never
# needs fork/exec — all sub-tools (mescc, M1, hex2) are driven from here.
#
# The MesCC build of `mes` (build-aux/build-mes.sh + bootstrap.sh.in) is:
#   * compile crt1 + libc (libc_mini/libmescc/libc *_SOURCES) with `mescc -c`
#   * archive with `mesar` — which is literally `cat` of the hex2 objects into
#     libX.a and `cat` of the .s into libX.s (scripts/mesar.in)
#   * link the 20 mes_SOURCES objects + libc with `mescc -nostdlib ... -lc -lmescc`
#     which assembles via M1 and links via hex2 at base 0x1000000.
# So the whole binary is a DETERMINISTIC function of the input .s set + the
# shared mescc-tools.  We build libc ONCE (host mes-m2, trusted-equally), then
# link a mes binary from a chosen host's 20 mes .s (mescc accepts .s inputs and
# assembles them).  Feeding qmes's F1 .s vs mes-m2's F1 .s and cmp'ing the two
# linked binaries is F2; hosting the F1 sweep on the qmes-linked binary is F3.
#
# Must run inside a shell that has mescc-tools (M1, hex2, blood-elf) on PATH,
# e.g.  nix shell nixpkgs#mescc-tools --command tools/mescc-link.sh ...
#
# Usage:
#   tools/mescc-link.sh libc                 # build libc once -> build/mescc-lib
#   tools/mescc-link.sh link SDIR OUT [JOBS] # link mes binary from SDIR/*.s
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
tp="$repo/third_party/mes"
root="$repo/build/mesroot"
lib="$repo/build/mescc-lib"          # libdir; built artifacts live in $lib/x86-mes/
adir="$lib/x86-mes"                   # arch-find resolves libX.a as x86-mes/libX.a

# Build-config knobs the MesCC path uses (build-aux/cflags.sh + configure).
mes_cpu=x86
mes_kernel=linux
compiler=mescc
mes_libc=mes
srcdest="$tp/"
export mes_cpu mes_kernel compiler mes_libc srcdest

command -v M1  >/dev/null 2>&1 || { echo "mescc-link: M1 not on PATH (need nix shell nixpkgs#mescc-tools)" >&2; exit 2; }
command -v hex2 >/dev/null 2>&1 || { echo "mescc-link: hex2 not on PATH" >&2; exit 2; }
[ -x "$repo/bin/mes-m2" ] || { echo "mescc-link: need bin/mes-m2 (make mes-reference)" >&2; exit 2; }
[ -f "$repo/build/include/mes/config.h" ] || "$repo/tools/mescc-fixpoint.sh" units >/dev/null # trigger ensure_env? no-op; config.h made below
if [ ! -f "$repo/build/include/mes/config.h" ]; then
    mkdir -p "$repo/build/include/mes"
    ver=$(sed -n 's/^VERSION=//p' "$tp/configure.sh" | head -1)
    printf '#undef SYSTEM_LIBC\n#define MES_VERSION "%s"\n' "${ver:-0.27.1}" > "$repo/build/include/mes/config.h"
fi
[ -d "$root/mes/module/nyacc/lang/c99" ] || "$repo/tools/make-mesroot.sh" >/dev/null

# The MesCC compiler driver (mes-m2 running mescc.scm), pinned like F1.
CC() {
    ( cd "$repo" && env -i \
        PATH="$PATH" LANG= MES_DEBUG=0 %version=0.27.1 MES_UNINSTALLED=1 \
        MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=6000000 \
        MES_PREFIX="$root" srcdest="$tp/" \
        GUILE_LOAD_PATH="$root/mes/module" \
        M1="$(command -v M1)" HEX2="$(command -v hex2)" BLOOD_ELF="$(command -v blood-elf)" \
        MES="$repo/bin/mes-m2" \
        "$repo/bin/mes-m2" --no-auto-compile -e main third_party/mes/module/mescc.scm -- "$@" )
}

CPPFLAGS="-m 32 --arch=x86 -D HAVE_CONFIG_H=1 -I build/include -I third_party/mes/include"

# Source the real SOURCES lists so we compile exactly what the MesCC build does.
# configure-lib.sh does `. ./config.sh`; we provide a stub carrying just the
# knobs the SOURCES lists depend on (mes_libc/mes_kernel/mes_cpu/compiler).
stubdir="$repo/build/fixpoint"
mkdir -p "$stubdir"
printf 'mes_cpu=x86\nmes_kernel=linux\ncompiler=mescc\nmes_libc=mes\nV=\n' > "$stubdir/config.sh"
sources() {
    ( set +eu
      cd "$stubdir"
      mes_cpu=x86 mes_kernel=linux compiler=mescc mes_libc=mes
      . "$tp/build-aux/configure-lib.sh" >/dev/null 2>&1
      case "$1" in
          libc_mini) printf '%s\n' $libc_mini_SOURCES ;;
          libmescc)  printf '%s\n' $libmescc_SOURCES ;;
          libc)      printf '%s\n' $libc_SOURCES ;;
          mes)       printf '%s\n' $mes_SOURCES ;;
      esac )
}

# compile_c REL_SRC OUT_O_ABS  — mescc -c one libc unit to a hex2 .o (+ .s).
compile_c() {
    _src=$1; _o=$2
    _base=$(basename "$_o" .o)
    _s="$(dirname "$_o")/$_base.s"
    # mescc -c writes <out>.o and, alongside, the M1 text as <out>.s.
    CC -c $CPPFLAGS -o "$_o" "$_src" >/dev/null 2>"$_o.log" || { echo "CC FAIL $_src"; cat "$_o.log" >&2; return 1; }
}

build_libc() {
    rm -rf "$lib"; mkdir -p "$adir"
    jobs=${1-16}
    # crt1
    echo "  crt1.c" >&2
    CC -c $CPPFLAGS -L build/mescc-lib -o "$adir/crt1.o" "$tp/lib/linux/x86-mes-mescc/crt1.c" >/dev/null 2>"$adir/crt1.log" \
        || { echo "crt1 FAIL"; cat "$adir/crt1.log" >&2; exit 1; }
    # compile a source list into $adir, echoing objects
    build_group() {
        _grp=$1; _n=0; _pids=""
        for c in $(sources "$_grp"); do
            b=$(echo "$c" | sed -e 's,^\./,,' -e 's,/,-,g' -e 's,\.c$,,')
            o="$adir/$b.o"
            ( compile_c "$tp/$c" "$o" && echo "done $c" || { echo "FAIL $c"; exit 1; } ) &
            _pids="$_pids $!"
            _n=$((_n + 1))
            while [ "$(jobs -r 2>/dev/null | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || break; done
        done
        _grpfail=0
        for p in $_pids; do wait "$p" || _grpfail=1; done
        return "$_grpfail"
    }
    # Run all three groups (|| true so one failing group still lets the others
    # report); the grep over the progress files below is the aggregate gate.
    echo "  libc_mini ($(sources libc_mini | wc -l) units)" >&2; build_group libc_mini >"$adir/mini.progress" 2>&1 || true
    echo "  libmescc  ($(sources libmescc  | wc -l) units)" >&2; build_group libmescc  >"$adir/mescc.progress" 2>&1 || true
    echo "  libc      ($(sources libc      | wc -l) units)" >&2; build_group libc      >"$adir/libc.progress" 2>&1 || true
    if grep -h '^FAIL' "$adir"/*.progress 2>/dev/null; then echo "build_libc: some units failed" >&2; exit 1; fi

    # Archive like mesar (cat): libX.a = cat objects, libX.s = cat .s.
    archive() {
        _name=$1; shift
        : > "$adir/$_name.a"; : > "$adir/$_name.s"
        for c in "$@"; do
            b=$(echo "$c" | sed -e 's,^\./,,' -e 's,/,-,g' -e 's,\.c$,,')
            cat "$adir/$b.o" >> "$adir/$_name.a"
            cat "$adir/$b.s" >> "$adir/$_name.s"
        done
    }
    archive libc     $(sources libc)
    archive libmescc $(sources libmescc)
    echo "build_libc: wrote $adir/{crt1.o,libc.a,libc.s,libmescc.a,libmescc.s}" >&2
}

link_mes() {
    sdir=$1; out=$2
    # 20 mes .s in mes_SOURCES order (link order must match for byte parity).
    sfiles=""
    for c in $(sources mes); do
        b=$(echo "$c" | sed -e 's,/,-,g' -e 's,\.c$,,')
        f="$sdir/$b.s"
        [ -f "$f" ] || { echo "link_mes: missing $f" >&2; exit 1; }
        sfiles="$sfiles $f"
    done
    mkdir -p "$(dirname "$out")" "$repo/build/fixpoint"
    _log="$repo/build/fixpoint/link-$(basename "$out").log"
    CC -m 32 --arch=x86 -nostdlib --base-address=0x1000000 \
        -L build/mescc-lib -o "$out" "$adir/crt1.o" $sfiles -lc -lmescc \
        >/dev/null 2>"$_log" || { echo "link FAIL (see $_log)"; tail -20 "$_log" >&2; exit 1; }
    chmod +x "$out"
    echo "link_mes: wrote $out" >&2
}

case "${1-}" in
    libc)  build_libc "${2-16}" ;;
    link)  link_mes "$2" "$3" ;;
    *) echo "usage: $0 {libc [JOBS] | link SDIR OUT}" >&2; exit 2 ;;
esac
