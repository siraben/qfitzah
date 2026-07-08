#!/bin/sh
# fixpoint-64.sh — the S8 x86_64 MesCC fixpoint (F1-64 / F2-64 / F3-64).
#
# A second, independent fixpoint to the i386 one (tools/fixpoint.sh), at the
# amd64 width.  Self-contained: it does NOT edit the i386 harness scripts.
#
#   F1-64  path-independent MesCC assembly: `mescc -S -m 64 --arch=x86_64` over
#          all 20 mes_SOURCES under BOTH ./qmes64.elf and bin/mes-m2-64,
#          byte-compared per unit.
#   F2-64  identical linked ELF64: build libc once (host mes-m2-64), link a mes
#          binary from each host's F1-64 .s set (mescc drives M1 amd64 /
#          blood-elf --64 / hex2 amd64 at base 0x1000000), cmp the two.
#   F3-64  self-recompilation: rerun the F1-64 sweep hosted on the qmes-path
#          amd64 mes binary (a native ELF64); its .s must equal F1-64's.
#
# F2/F3 need mescc-tools (M1/hex2/blood-elf); this script self-enters
# `nix shell nixpkgs#mescc-tools` if they are not already on PATH.
# bin/mes-m2-64 (ARCH=x86_64 make mes-reference) and qmes64.elf
# (tools/build-qmes64.sh) must already exist.
#
# Determinism contract is identical to the i386 harness (env -i, LANG=,
# %version pinned, fixed MES_ARENA/STACK, MES_PREFIX=merged mesroot, repo-
# relative -o canon label) plus %arch=x86_64 so mescc's getenv fallback agrees
# with --arch=x86_64.  qmes64 is an i386 process so its arena stays <= 50M.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
tp="$repo/third_party/mes"
root="$repo/build/mesroot"
moduledir="$root/mes/module"
sc="$repo/build/fixpoint64"
refhash="$repo/tests/mescc-references/fixpoint-64/f1-64.sha256"
binhash="$repo/tests/mescc-references/fixpoint-64/mes-mescc64.sha256"
JOBS=${JOBS-16}
# qmes64 is a 32-bit process: keep its cell arena within the i386 address space.
QMES64_ARENA=${QMES64_ARENA-50000000}

UNITS="
src/builtins.c
src/cc.c
src/core.c
src/display.c
src/eval-apply.c
src/gc.c
src/globals.c
src/hash.c
src/lib.c
src/math.c
src/mes.c
src/module.c
src/posix.c
src/reader.c
src/stack.c
src/string.c
src/struct.c
src/symbol.c
src/variable.c
src/vector.c
"

ensure_env() {
    [ -d "$moduledir/nyacc/lang/c99" ] || "$repo/tools/make-mesroot.sh" >/dev/null
    inc="$repo/build/include-64"
    cfg="$inc/mes/config.h"
    if [ ! -f "$cfg" ]; then
        mkdir -p "$inc/mes"
        ver=$(sed -n 's/^VERSION=//p' "$tp/configure.sh" | head -1)
        printf '#undef SYSTEM_LIBC\n#define MES_VERSION "%s"\n' "${ver:-0.27.1}" > "$cfg"
    fi
    if [ ! -e "$inc/arch/signal.h" ]; then
        mkdir -p "$inc/arch"
        for h in kernel-stat.h signal.h syscall.h; do
            ln -sf "$tp/include/linux/x86_64/$h" "$inc/arch/$h"
        done
    fi
}

# compile_one HOST REL_IN.c REL_OUT.s [ARENA] — one `mescc -S -m 64` invocation.
compile_one() {
    _host=$1; _in=$2; _out=$3; _arena=${4-20000000}
    mkdir -p "$repo/$(dirname "$_out")"
    ( cd "$repo" && exec env -i \
        PATH="$PATH" LANG= MES_DEBUG=0 \
        %version=0.27.1 %arch=x86_64 \
        MES_ARENA="$_arena" MES_MAX_ARENA="$_arena" MES_STACK="${MES_STACK-8000000}" \
        MES_PREFIX="$root" srcdest="$tp/" \
        GUILE_LOAD_PATH="$moduledir" \
        "$_host" \
            --no-auto-compile -e main third_party/mes/module/mescc.scm -- \
            -S -m 64 --arch=x86_64 \
            -D HAVE_CONFIG_H=1 \
            -I build/include-64 \
            -I third_party/mes/include \
            -o "$_out" \
            "$_in" )
}

# compile HOST OUTDIR [JOBS] [ARENA] — sweep all 20 units on one host.
do_compile() {
    host=$1; outdir=$2; jobs=${3-8}; arena=${4-20000000}
    ensure_env
    mkdir -p "$outdir"
    case "$host" in /*) : ;; *) host="$repo/$host" ;; esac
    canon_rel="build/fixpoint64/canon"
    mkdir -p "$repo/$canon_rel"
    outdir_abs=$(cd "$outdir" && pwd)
    for u in $UNITS; do
        base=$(echo "$u" | sed -e 's,/,-,g' -e 's,\.c$,,')
        cout="$canon_rel/$base.s"
        out="$outdir_abs/$base.s"
        log="$outdir_abs/$base.log"
        ( if compile_one "$host" "third_party/mes/$u" "$cout" "$arena" >"$log" 2>&1; then
              mv -f "$repo/$cout" "$out"; echo "done $u"
          else rm -f "$repo/$cout"; echo "FAIL $u (see $log)"; fi ) &
        while [ "$(jobs -r 2>/dev/null | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || break; done
    done
    wait
}

# ---- F2-64 support: libc + link, amd64 ---------------------------------------
# NOTE on the driver split: bin/mes-m2-64's `system*` is broken (it returns a
# stack pointer instead of the child's wait status), so it CANNOT reliably drive
# M1/hex2 to assemble/link.  bin/mes-m2 (i386, the trusted reference) drives them
# correctly but cannot COMPILE 64-bit code.  So:
#   * codegen (C -> .s, needs 64-bit): bin/mes-m2-64  `mescc -S`   (no system*)
#   * assemble (.s -> .o) + link      : M1/blood-elf/hex2, orchestrated either
#     directly (assemble) or by bin/mes-m2 driving mescc's link (proven to
#     produce a runnable ELF64).  M1/hex2 do all amd64 work — same trust model
#     as the i386 F2.
lib="$repo/build/mescc-lib-64"
adir="$lib/x86_64-mes"
M1MACROS="$tp/lib/x86_64-mes/x86_64.M1"
# CC64_S: bin/mes-m2-64 mescc -S (compile a C unit to amd64 .s; clean exit).
CC64_S() {
    ( cd "$repo" && env -i \
        PATH="$PATH" LANG= MES_DEBUG=0 %version=0.27.1 %arch=x86_64 MES_UNINSTALLED=1 \
        MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=8000000 \
        MES_PREFIX="$root" srcdest="$tp/" GUILE_LOAD_PATH="$moduledir" \
        "$repo/bin/mes-m2-64" --no-auto-compile -e main third_party/mes/module/mescc.scm -- \
        -S "$@" )
}
# M1ASM: assemble one amd64 .s to a hex2 .o exactly as `mescc -c` would.
M1ASM() { # M1ASM IN.s OUT.o
    M1 --little-endian --architecture amd64 -f "$M1MACROS" -f "$1" -o "$2"
}
# CC64LINK: bin/mes-m2 (i386) driving mescc's linker (drives M1/blood-elf/hex2).
CC64LINK() {
    ( cd "$repo" && env -i \
        PATH="$PATH" LANG= MES_DEBUG=0 %version=0.27.1 %arch=x86_64 MES_UNINSTALLED=1 \
        MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=8000000 \
        MES_PREFIX="$root" srcdest="$tp/" GUILE_LOAD_PATH="$moduledir" \
        M1="$(command -v M1)" HEX2="$(command -v hex2)" BLOOD_ELF="$(command -v blood-elf)" \
        MES="$repo/bin/mes-m2-64" \
        "$repo/bin/mes-m2" --no-auto-compile -e main third_party/mes/module/mescc.scm -- "$@" )
}
CPP64="-m 64 --arch=x86_64 -D HAVE_CONFIG_H=1 -I build/include-64 -I third_party/mes/include"
sources() {
    ( set +eu; cd "$sc"
      mes_cpu=x86_64 mes_kernel=linux compiler=mescc mes_libc=mes
      . "$tp/build-aux/configure-lib.sh" >/dev/null 2>&1
      case "$1" in
          libc_mini) printf '%s\n' $libc_mini_SOURCES ;;
          libmescc)  printf '%s\n' $libmescc_SOURCES ;;
          libc)      printf '%s\n' $libc_SOURCES ;;
          mes)       printf '%s\n' $mes_SOURCES ;;
      esac )
}
build_libc() {
    ensure_env
    mkdir -p "$sc"
    printf 'mes_cpu=x86_64\nmes_kernel=linux\ncompiler=mescc\nmes_libc=mes\nV=\n' > "$sc/config.sh"
    rm -rf "$lib"; mkdir -p "$adir"
    jobs=${1-16}
    # compile1 SRC BASE: mes-m2-64 -S -> BASE.s, then M1 -> BASE.o (like mescc -c).
    compile1() {
        _src=$1; _b=$2
        CC64_S $CPP64 -o "$adir/$_b.s" "$_src" >/dev/null 2>"$adir/$_b.log" \
            || { echo "FAIL $_src (compile)"; return 1; }
        M1ASM "$adir/$_b.s" "$adir/$_b.o" >>"$adir/$_b.log" 2>&1 \
            || { echo "FAIL $_src (assemble)"; return 1; }
        echo "done $_src"
    }
    echo "  crt1.c" >&2
    compile1 "$tp/lib/linux/x86_64-mes-mescc/crt1.c" crt1 >"$adir/crt1.progress" 2>&1 \
        || { echo "crt1 FAIL"; cat "$adir/crt1.log" >&2; exit 1; }
    build_group() {
        _grp=$1
        for c in $(sources "$_grp"); do
            b=$(echo "$c" | sed -e 's,^\./,,' -e 's,/,-,g' -e 's,\.c$,,')
            ( compile1 "$tp/$c" "$b" ) &
            while [ "$(jobs -r 2>/dev/null | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || break; done
        done
        wait
    }
    echo "  libc_mini" >&2; build_group libc_mini >"$adir/mini.progress" 2>&1
    echo "  libmescc"  >&2; build_group libmescc  >"$adir/mescc.progress" 2>&1
    echo "  libc"      >&2; build_group libc      >"$adir/libc.progress" 2>&1
    if grep -h '^FAIL' "$adir"/*.progress 2>/dev/null; then echo "build_libc: units failed" >&2; exit 1; fi
    archive() {
        _name=$1; shift
        : > "$adir/$_name.a"; : > "$adir/$_name.s"
        for c in "$@"; do
            b=$(echo "$c" | sed -e 's,^\./,,' -e 's,/,-,g' -e 's,\.c$,,')
            cat "$adir/$b.o" >> "$adir/$_name.a"; cat "$adir/$b.s" >> "$adir/$_name.s"
        done
    }
    archive libc     $(sources libc)
    archive libmescc $(sources libmescc)
    echo "build_libc: wrote $adir/{crt1.o,libc.a,libmescc.a}" >&2
}
# link_mes: assemble the 20 mes .s (in mes_SOURCES order) with M1 into one hex2
# object, then hex2-link (elf64 header + crt1 + mes.o + libmescc.a + libc.a +
# elf64 single-main footer) at base 0x1000000 -> a runnable amd64 ELF64.  This
# is exactly what `mescc -nostdlib --base-address=0x1000000 -lc -lmescc` runs
# (captured from its command trace), but invoked directly so no flaky mes
# `system*` wait-status is in the path.  M1/hex2 do all the amd64 work.
hdr="$tp/lib/linux/x86_64-mes/elf64-header.hex2"
ftr="$tp/lib/linux/x86_64-mes/elf64-footer-single-main.hex2"
link_mes() {
    sdir=$1; out=$2
    sfiles=""
    for c in $(sources mes); do
        b=$(echo "$c" | sed -e 's,/,-,g' -e 's,\.c$,,')
        f="$sdir/$b.s"
        [ -f "$f" ] || { echo "link_mes: missing $f" >&2; exit 1; }
        sfiles="$sfiles -f $f"
    done
    mkdir -p "$(dirname "$out")" "$sc"
    _obj="$sc/$(basename "$out").mes.o"
    _log="$sc/link-$(basename "$out").log"
    M1 --little-endian --architecture amd64 -f "$M1MACROS" $sfiles -o "$_obj" 2>"$_log" \
        || { echo "link FAIL (M1, see $_log)"; tail -20 "$_log" >&2; exit 1; }
    hex2 --little-endian --architecture amd64 --base-address 0x1000000 \
        -f "$hdr" -f "$adir/crt1.o" -f "$_obj" \
        -f "$adir/libmescc.a" -f "$adir/libc.a" -f "$ftr" \
        -o "$out" 2>>"$_log" \
        || { echo "link FAIL (hex2, see $_log)"; tail -20 "$_log" >&2; exit 1; }
    chmod +x "$out"
    echo "link_mes: wrote $out" >&2
}

case "${1-}" in
  units) for u in $UNITS; do echo "$u"; done ;;
  compile) do_compile "$2" "$3" "${4-8}" "${5-20000000}" ;;
  libc) build_libc "${2-16}" ;;
  link) link_mes "$2" "$3" ;;
  verify)
    # Offline F1-64 gate: sweep qmes64 only, check against committed hashes.
    jobs=${2-8}
    [ -f "$refhash" ] || { echo "verify: missing $refhash" >&2; exit 2; }
    [ -x "$repo/qmes64.elf" ] || { echo "verify: build qmes64 first" >&2; exit 2; }
    out="$sc/verify"; rm -rf "$out"; mkdir -p "$out"
    do_compile "$repo/qmes64.elf" "$out" "$jobs" "$QMES64_ARENA" >/dev/null
    ( cd "$out" && sha256sum -c "$refhash" ) \
      && echo "verify: F1-64 OK — all $(grep -c . "$refhash") units byte-identical to reference" \
      || { echo "verify: F1-64 FAILED" >&2; exit 1; }
    ;;
  all|"")
    if ! command -v M1 >/dev/null 2>&1 || ! command -v hex2 >/dev/null 2>&1; then
        echo "fixpoint-64: entering nix shell for mescc-tools" >&2
        exec nix shell nixpkgs#mescc-tools --command "$0" "${1-all}"
    fi
    [ -x "$repo/qmes64.elf" ]     || { echo "build qmes64 first (tools/build-qmes64.sh)" >&2; exit 2; }
    [ -x "$repo/bin/mes-m2-64" ]  || { echo "need bin/mes-m2-64 (ARCH=x86_64 make mes-reference)" >&2; exit 2; }
    echo "==================== F1-64: path-independent MesCC assembly ===================="
    rm -rf "$sc/f1-ref" "$sc/f1-qmes"; mkdir -p "$sc/f1-ref" "$sc/f1-qmes"
    echo "F1-64: sweep bin/mes-m2-64 (native) ..."
    do_compile "$repo/bin/mes-m2-64" "$sc/f1-ref" "$JOBS" 20000000 >/dev/null
    echo "F1-64: sweep ./qmes64.elf (interpreted + w64-in-Scheme — slow) ..."
    do_compile "$repo/qmes64.elf" "$sc/f1-qmes" "$JOBS" "$QMES64_ARENA" >/dev/null
    f1pass=0; f1div=0
    for f in "$sc"/f1-ref/*.s; do
        b=$(basename "$f")
        if cmp -s "$sc/f1-ref/$b" "$sc/f1-qmes/$b"; then f1pass=$((f1pass+1))
        else echo "  F1-64 DIVERGE $b: $(cmp "$sc/f1-ref/$b" "$sc/f1-qmes/$b" 2>&1)"; f1div=$((f1div+1)); fi
    done
    echo "F1-64: $f1pass/20 byte-identical, $f1div diverge"
    [ "$f1div" = 0 ] || { echo "F1-64 FAILED"; exit 1; }
    mkdir -p "$(dirname "$refhash")"
    ( cd "$sc/f1-qmes" && sha256sum *.s > "$refhash" )
    echo "F1-64: committed reference hashes -> $refhash"

    echo "==================== F2-64: identical linked ELF64 ===================="
    echo "F2-64: building libc once (host bin/mes-m2-64) ..."
    build_libc "$JOBS" 2>&1 | sed 's/^/  /'
    echo "F2-64: linking mes from the mes-m2-64 F1 .s -> bin/mes-mescc64.ref ..."
    link_mes "$sc/f1-ref"  "$repo/bin/mes-mescc64.ref"  2>&1 | sed 's/^/  /'
    echo "F2-64: linking mes from the qmes64  F1 .s -> bin/mes-mescc64.qmes ..."
    link_mes "$sc/f1-qmes" "$repo/bin/mes-mescc64.qmes" 2>&1 | sed 's/^/  /'
    if cmp -s "$repo/bin/mes-mescc64.ref" "$repo/bin/mes-mescc64.qmes"; then
        got=$(sha256sum "$repo/bin/mes-mescc64.qmes" | awk '{print $1}')
        echo "F2-64: LINKED ELF64 BYTE-IDENTICAL  sha256=$got  size=$(wc -c < "$repo/bin/mes-mescc64.qmes")"
        mkdir -p "$(dirname "$binhash")"; echo "$got  bin/mes-mescc64.qmes" > "$binhash"
    else
        echo "F2-64 FAILED: ref != qmes" >&2; exit 1
    fi
    echo "F2-64: smoke — the linked ELF64 runs natively:"
    env -i MES_PREFIX="$root" %version=0.27.1 GUILE_LOAD_PATH="$moduledir" \
        "$repo/bin/mes-mescc64.qmes" -c "(display (+ 40 2))(newline)" 2>&1 | sed 's/^/  /'

    echo "==================== F3-64: self-recompilation fixpoint ===================="
    echo "F3-64: rerun the F1-64 sweep hosted on the qmes-path amd64 mes ..."
    rm -rf "$sc/f3"; mkdir -p "$sc/f3"
    do_compile "$repo/bin/mes-mescc64.qmes" "$sc/f3" "$JOBS" 20000000 >/dev/null
    ( cd "$sc/f3" && sha256sum -c "$refhash" >/dev/null ) \
      && echo "F3-64: 20/20 units match F1-64 — self-recompilation fixpoint reached" \
      || { echo "F3-64 FAILED" >&2; exit 1; }
    echo "============================================================================"
    echo "S8 FIXPOINT ACHIEVED (x86_64): F1-64 20/20 | F2-64 byte-identical ELF64 | F3-64 20/20"
    ;;
  *) echo "usage: $0 {all | compile HOST OUTDIR [JOBS] [ARENA] | libc | link SDIR OUT | verify [JOBS] | units}" >&2; exit 2 ;;
esac
