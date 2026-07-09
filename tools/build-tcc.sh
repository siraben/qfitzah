#!/usr/bin/env bash
# build-tcc.sh — the qmes → MesCC → TinyCC bootstrap rung (docs/mes-bootstrap.md).
#
# The thesis: qmes's MesCC compiles the full TinyCC byte-identically to the
# M2-Planet-reference MesCC path (bin/mes-m2).  We mirror the F1/F2/F3
# machinery of tools/mescc-fixpoint.sh + tools/mescc-link.sh + tools/fixpoint.sh
# exactly, one rung up: the 10 tcc translation units are the compile set, tcc
# links against the `libc+tcc` flavor of the Mes libc, and the reference is the
# same tcc built under bin/mes-m2 (fast), byte-compared against the qmes build.
#
# Gates (docs/mes-bootstrap.md, tcc rung):
#   T0  reference tcc under bin/mes-m2: 10 units -> tcc-mes.ref -> stage libc ->
#       hello (exit 42) -> self-host boot chain -> cmp tcc-boot5 tcc-boot6.
#       Commit the reference .s + binary sha256 set.
#   T1  qmes F1-analog: qmes compiles the same 10 units with bit-identical
#       argv/env and canonical -o; cmp each against T0.  Gate: 10/10 identical.
#   T2  link tcc from the qmes .s set (same mescc-tools); cmp the binary against
#       the mes-m2-linked one; then the hello gate using the qmes-built tcc.
#   T3  tcc self-host fixpoint seeded from the qmes tcc: cmp tcc-boot5 tcc-boot6.
#
# Determinism contract (identical to F1, docs/mes-bootstrap.md): env -i,
# LANG=, MES_DEBUG=0, %version=0.27.1, MES_PREFIX=build/mesroot,
# srcdest=third_party/mes/, GUILE_LOAD_PATH=$moduledir, run from repo root,
# MES_ARENA=MES_MAX_ARENA=20000000, MES_STACK=10000000; the -o label is the
# repo-relative build/tcc/canon/<u>.s path (MesCC embeds it verbatim), and every
# -D string is a fixed literal with no machine-absolute path.  config.h is one
# line under build/tcc/include, supplied via -I, submodule stays pristine.
#
# Usage:
#   tools/build-tcc.sh units                       # print the 10-unit list
#   tools/build-tcc.sh libc [JOBS]                 # build the libc+tcc flavor
#   tools/build-tcc.sh compile HOST OUTDIR [JOBS]  # 10-unit mescc -S sweep
#   tools/build-tcc.sh link SDIR OUT               # link tcc from SDIR/*.s
#   tools/build-tcc.sh stage TCC                   # crt+libc+libtcc1 stage
#   tools/build-tcc.sh hello TCC                   # compile+run hello.c (exit 42)
#   tools/build-tcc.sh boot TCC [N]                # self-host chain to boot N
#   tools/build-tcc.sh t0 [JOBS]                   # full T0 reference + hashes
#   tools/build-tcc.sh verify [JOBS]               # offline: qmes sweep vs hashes
#   tools/build-tcc.sh fixpoint [JOBS]             # T1+T2+T3 (qmes vs reference)
#
# link/stage/hello/boot/t0/fixpoint need mescc-tools (M1/hex2/blood-elf) on PATH
# (nix shell nixpkgs#mescc-tools); compile/units/verify do not.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
tp="$repo/third_party/mes"
tcc="$repo/third_party/tinycc"
root="$repo/build/mesroot"
moduledir="$root/mes/module"

# Shared scrubbed `env -i ... mescc.scm --` MesCC driver (byte-identical to the
# hand-written form); this script keeps its own arch/arena/include policy.
. "$repo/tools/lib/mescc.sh"
lib="$repo/build/mescc-lib"          # shared with mescc-link.sh (crt1.o, libmescc)
adir="$lib/x86-mes"
bdir="$repo/build/tcc"               # all tcc intermediates live here
inc="$bdir/include"                  # holds the synthesized config.h
canon_rel="build/tcc/canon"          # repo-relative -o label (host-independent)
refdir="$repo/tests/references/mescc/tcc"

# The 10 tcc translation units, in bootstrap.sh link order (link order affects
# bytes — pin it).  i386 target => ${tcc_cpu}=i386.
TCC_UNITS="tccpp tccgen tccelf tccrun i386-gen i386-link i386-asm tccasm libtcc tcc"

# The fixed -D block (docs/mes-bootstrap.md, transcribed from bootstrap.sh's
# x86 arm).  No HAVE_FLOAT/LONG_LONG/SETJMP/BITFIELD at the mescc stage.  No
# machine-absolute path: the CONFIG_TCC_* literals are tcc's runtime defaults;
# our harness always passes -B/-I/-L explicitly, so they never need to resolve.
#
# CRITICAL: the string-valued macros MUST carry embedded double-quotes so they
# expand to C string literals — e.g. CONFIG_TCC_CRTPREFIX="/usr/local/lib:..."
# not /usr/local/lib:... (which the C parser reads as a division expression and
# rejects with `parse failed ... on input "/"`).  Emitted one-per-NUL-token so
# the quotes survive word-splitting when the caller does `$(tcc_defines)`.
# Callers must set IFS=newline (the sweep does) so each line is one argv word.
tcc_defines() {
    cat <<'EOF'
-D
BOOTSTRAP=1
-D
TCC_TARGET_I386=1
-D
CONFIG_TCCDIR="/usr/local/lib/tcc"
-D
CONFIG_TCC_CRTPREFIX="/usr/local/lib:{B}/lib:."
-D
CONFIG_TCC_ELFINTERP="/mes/loader"
-D
CONFIG_TCC_LIBPATHS="/usr/local/lib:{B}/lib:."
-D
CONFIG_TCC_SYSINCLUDEPATHS="/usr/local/include:{B}/include"
-D
TCC_LIBGCC="/usr/local/lib/libc.a"
-D
CONFIG_TCCBOOT=1
-D
CONFIG_TCC_STATIC=1
-D
CONFIG_USE_LIBGCC=1
-D
TCC_MES_LIBC=1
-D
TCC_LIBTCC1_MES="libtcc1-mes.a"
EOF
}

ensure_env() {
    [ -d "$moduledir/nyacc/lang/c99" ] || "$repo/tools/make-mesroot.sh" >/dev/null
    # config.h: the one synthesized file (docs/mes-bootstrap.md).  Written
    # OUTSIDE the submodule, resolved via -I build/tcc/include — MesCC resolves
    # quoted #include "config.h" through the -I chain.
    mkdir -p "$inc"
    if [ ! -f "$inc/config.h" ]; then
        printf '#define TCC_VERSION "0.9.27"\n' > "$inc/config.h"
    fi
    # <mes/config.h> for the libc build path (shared with mescc-fixpoint.sh).
    if [ ! -f "$repo/build/include/mes/config.h" ]; then
        mkdir -p "$repo/build/include/mes"
        ver=$(sed -n 's/^VERSION=//p' "$tp/configure.sh" | head -1)
        printf '#undef SYSTEM_LIBC\n#define MES_VERSION "%s"\n' "${ver:-0.27.1}" > "$repo/build/include/mes/config.h"
    fi
    # arch/*.h symlinks the libc units need (<arch/syscall.h> etc.).
    if [ ! -e "$repo/build/include/arch/signal.h" ]; then
        mkdir -p "$repo/build/include/arch"
        for h in kernel-stat.h signal.h syscall.h; do
            ln -sf "$tp/include/linux/x86/$h" "$repo/build/include/arch/$h"
        done
    fi
}

# ---- one MesCC -S invocation for a tcc unit (deterministic env, §2.2) --------
# compile_one HOST unit  -> writes $canon_rel/$unit.s (repo-relative -o label)
# Splits tcc_defines on newlines only (IFS) so quoted -D values with spaces
# ("/usr/local/lib:{B}/lib:.") stay a single argv word.
compile_one() {
    _host=$1; _unit=$2
    _oldifs=$IFS
    IFS='
'
    set -- $(tcc_defines)
    IFS=$_oldifs
    # $@ now holds the -D block (quoted values preserved as single words).
    ( cd "$repo" \
      && export MES_PREFIX="$root" MES_SRCDEST="$tp/" MES_MODULEDIR="$moduledir" \
                MES_ARENA="${MES_ARENA-20000000}" MES_MAX_ARENA="${MES_MAX_ARENA-20000000}" \
                MES_STACK="${MES_STACK-10000000}" \
      && mescc_run "$_host" \
            -- \
            -S -m 32 --arch=x86 \
            "$@" \
            -I "$canon_rel/../include" \
            -I third_party/tinycc \
            -I third_party/mes/lib \
            -I third_party/mes/include \
            -o "$canon_rel/$_unit.s" \
            "third_party/tinycc/$_unit.c" )
}

# sweep HOST OUTDIR JOBS — compile all 10 units under HOST into OUTDIR (per-unit
# logs), moving each canonical .s into OUTDIR.  Mirrors mescc-fixpoint.sh.
sweep() {
    host=$1; outdir=$2; jobs=${3-8}
    ensure_env
    mkdir -p "$outdir" "$repo/$canon_rel"
    case "$host" in /*) : ;; *) host="$repo/$host" ;; esac
    outdir_abs=$(cd "$outdir" && pwd)
    pids=""
    for u in $TCC_UNITS; do
        cout="$canon_rel/$u.s"
        out="$outdir_abs/$u.s"
        log="$outdir_abs/$u.log"
        ( if compile_one "$host" "$u" >"$log" 2>&1; then
              mv -f "$repo/$cout" "$out"; echo "done $u"
          else
              rm -f "$repo/$cout"; echo "FAIL $u (see $log)"; exit 1
          fi ) &
        pids="$pids $!"
        while [ "$(jobs -r 2>/dev/null | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || break; done
    done
    _fail=0
    for p in $pids; do wait "$p" || _fail=1; done
    [ "$_fail" = 0 ] || { echo "sweep: some units failed" >&2; return 1; }
}

# ---- mescc-tools driver (M1/hex2/blood-elf); same CC() as mescc-link.sh ------
# Verbs that link/stage/boot need mescc-tools on PATH; self-enter the nix shell
# (like tools/fixpoint.sh) if they are missing.
enter_nix_if_needed() {
    if ! command -v M1 >/dev/null 2>&1 || ! command -v hex2 >/dev/null 2>&1; then
        command -v nix >/dev/null 2>&1 || { echo "build-tcc: need mescc-tools (M1/hex2/blood-elf) and no nix to fetch them" >&2; exit 2; }
        echo "build-tcc: entering nix shell for mescc-tools" >&2
        exec nix shell nixpkgs#mescc-tools --command "$0" "$@"
    fi
}
need_tools() {
    command -v M1 >/dev/null 2>&1 || { echo "build-tcc: M1 not on PATH (nix shell nixpkgs#mescc-tools)" >&2; exit 2; }
    command -v hex2 >/dev/null 2>&1 || { echo "build-tcc: hex2 not on PATH" >&2; exit 2; }
    [ -x "$repo/bin/mes-m2" ] || { echo "build-tcc: need bin/mes-m2 (make mes-reference)" >&2; exit 2; }
}
CC() {
    ( cd "$repo" && env -i \
        PATH="$PATH" LANG= MES_DEBUG=0 %version=0.27.1 MES_UNINSTALLED=1 \
        MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=10000000 \
        MES_PREFIX="$root" srcdest="$tp/" \
        GUILE_LOAD_PATH="$root/mes/module" \
        M1="$(command -v M1)" HEX2="$(command -v hex2)" BLOOD_ELF="$(command -v blood-elf)" \
        MES="$repo/bin/mes-m2" \
        "$repo/bin/mes-m2" --no-auto-compile -e main third_party/mes/module/mescc.scm -- "$@" )
}

# ---- libc+tcc (docs/mes-bootstrap.md) ----------------------------------------
# The libc+tcc SOURCES from configure-lib.sh, sourced like mescc-link.sh does.
stubdir="$repo/build/fixpoint"
sources_tcc() {
    ensure_env
    mkdir -p "$stubdir"
    printf 'mes_cpu=x86\nmes_kernel=linux\ncompiler=mescc\nmes_libc=mes\nV=\n' > "$stubdir/config.sh"
    ( set +eu
      cd "$stubdir"
      mes_cpu=x86 mes_kernel=linux compiler=mescc mes_libc=mes
      . "$tp/build-aux/configure-lib.sh" >/dev/null 2>&1
      case "$1" in
          libc_mini)  printf '%s\n' $libc_mini_SOURCES ;;
          libmescc)   printf '%s\n' $libmescc_SOURCES ;;
          libc_tcc)   printf '%s\n' $libc_tcc_SOURCES ;;
      esac )
}
CPPFLAGS_LIBC="-m 32 --arch=x86 -D HAVE_CONFIG_H=1 -I build/include -I third_party/mes/include"
compile_c() {
    _src=$1; _o=$2
    CC -c $CPPFLAGS_LIBC -o "$_o" "$_src" >/dev/null 2>"$_o.log" \
        || { echo "CC FAIL $_src"; cat "$_o.log" >&2; return 1; }
}
build_libc() {
    jobs=${1-16}
    need_tools; ensure_env
    rm -rf "$lib"; mkdir -p "$adir"
    echo "  crt1.c" >&2
    CC -c $CPPFLAGS_LIBC -L build/mescc-lib -o "$adir/crt1.o" "$tp/lib/linux/x86-mes-mescc/crt1.c" \
        >/dev/null 2>"$adir/crt1.log" || { echo "crt1 FAIL"; cat "$adir/crt1.log" >&2; exit 1; }
    build_group() {
        _grp=$1; _pids=""
        for c in $(sources_tcc "$_grp"); do
            b=$(echo "$c" | sed -e 's,^\./,,' -e 's,/,-,g' -e 's,\.c$,,')
            ( compile_c "$tp/$c" "$adir/$b.o" && echo "done $c" || { echo "FAIL $c"; exit 1; } ) &
            _pids="$_pids $!"
            while [ "$(jobs -r 2>/dev/null | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || break; done
        done
        _grpfail=0
        for p in $_pids; do wait "$p" || _grpfail=1; done
        return "$_grpfail"
    }
    # Run all three groups (|| true so one failing group still lets the others
    # report); the grep over the progress files below is the aggregate gate.
    echo "  libc_mini ($(sources_tcc libc_mini | wc -l) units)" >&2; build_group libc_mini >"$adir/mini.progress" 2>&1 || true
    echo "  libmescc  ($(sources_tcc libmescc  | wc -l) units)" >&2; build_group libmescc  >"$adir/mescc.progress" 2>&1 || true
    echo "  libc+tcc  ($(sources_tcc libc_tcc  | wc -l) units)" >&2; build_group libc_tcc  >"$adir/tcc.progress" 2>&1 || true
    if grep -h '^FAIL' "$adir"/*.progress 2>/dev/null; then echo "build_libc: some units failed" >&2; exit 1; fi
    # mesar archive (cat): both libc+tcc.a and libc+tcc.s (the .s archive is NOT
    # optional — mescc linking from .s inputs resolves -l c+tcc to x86-mes/libc+tcc.s).
    archive() {
        _name=$1; shift
        : > "$adir/$_name.a"; : > "$adir/$_name.s"
        for c in "$@"; do
            b=$(echo "$c" | sed -e 's,^\./,,' -e 's,/,-,g' -e 's,\.c$,,')
            cat "$adir/$b.o" >> "$adir/$_name.a"
            cat "$adir/$b.s" >> "$adir/$_name.s"
        done
    }
    archive "libc+tcc" $(sources_tcc libc_tcc)
    archive libmescc   $(sources_tcc libmescc)
    # mescc's default link (no -nostdlib) always appends `-l c`, resolving to
    # x86-mes/libc.{a,s}.  Our libc+tcc is a superset of plain libc, so provide
    # libc.{a,s} as copies — the link uses -l c (libc.a) + -l c+tcc (the tcc
    # runtime superset); duplicate defs resolve first-wins in the hex2 link.
    cp "$adir/libc+tcc.a" "$adir/libc.a"
    cp "$adir/libc+tcc.s" "$adir/libc.s"
    echo "build_libc: wrote $adir/{crt1.o,libc{,+tcc}.{a,s},libmescc.{a,s}}" >&2
}

# ---- link (docs/mes-bootstrap.md) --------------------------------------------
link_tcc() {
    sdir=$1; out=$2
    need_tools
    [ -f "$adir/libc+tcc.s" ] || { echo "link_tcc: build libc first (build-tcc.sh libc)" >&2; exit 1; }
    sfiles=""
    for u in $TCC_UNITS; do
        f="$sdir/$u.s"
        [ -f "$f" ] || { echo "link_tcc: missing $f" >&2; exit 1; }
        sfiles="$sfiles $f"
    done
    mkdir -p "$(dirname "$out")"
    _log="$bdir/link-$(basename "$out").log"
    # Proven recipe (Fable's working scratchpad link): let mescc's default link
    # add crt1.o + the standard set; supply only -L build/mescc-lib and the
    # libc+tcc superset via -l c+tcc.  The -nostdlib + explicit crt1.o + -l mescc
    # shape (borrowed from the F2-mes link) does NOT produce a working tcc.
    CC -m 32 --arch=x86 -o "$out" -L build/mescc-lib \
        $sfiles -l c+tcc \
        >/dev/null 2>"$_log" || { echo "link FAIL (see $_log)"; tail -30 "$_log" >&2; exit 1; }
    chmod +x "$out"
    echo "link_tcc: wrote $out ($(wc -c <"$out") B)" >&2
}

# ---- stage: build crt/libc/libtcc1 with the tcc under test (docs/mes-bootstrap.md) --
# Build crt{1,i,n}.o, libc.a, libtcc1.a with the tcc under test, into
# build/tcc/stage.  The tcc-built libc must be the compiler=gcc source variants
# (gcc-style asm(); the mescc variants are M1 text and fail under tcc).
STAGE_CPPFLAGS="-I build/include -I third_party/mes/include -I third_party/mes/lib -D BOOTSTRAP=1"
gen_amalgams() {
    # Produce build/tcc/src/{libc.c,libtcc1.c,crt*.c} via build-source-lib.sh
    # with compiler=gcc, mirroring bootstrap.sh's REBUILD_LIBC arm.  configure-
    # lib.sh does `. ./config.sh`, so drop a config.sh stub (compiler=gcc) first.
    src="$bdir/src"; rm -rf "$src"; mkdir -p "$src"
    printf 'mes_cpu=x86\nmes_kernel=linux\ncompiler=gcc\nmes_libc=mes\nmes_bits=32\nmes_system=x86-mes\nV=\n' > "$src/config.sh"
    ( cd "$src" && env -i PATH="$PATH" \
        mes_cpu=x86 mes_kernel=linux compiler=gcc mes_libc=mes mes_bits=32 mes_system=x86-mes \
        srcdest="$tp/" sh "$tp/build-aux/build-source-lib.sh" >"$bdir/gen-amalgams.log" 2>&1 ) \
        || { echo "gen_amalgams FAIL"; tail -15 "$bdir/gen-amalgams.log" >&2; exit 1; }
    # build-source-lib.sh emits libc+gnu.c; the plan uses that as libc.c.
    cp -f "$src/libc+gnu.c" "$src/libc.c"
}
stage_tcc() {
    thetcc=$1
    need_tools; ensure_env; gen_amalgams
    st="$bdir/stage"; rm -rf "$st"; mkdir -p "$st/lib/tcc"
    src="$bdir/src"
    run() { ( cd "$repo" && "$thetcc" "$@" ); }
    for i in 1 i n; do
        run -c -static -nostdlib -nostdinc $STAGE_CPPFLAGS \
            -o "$st/lib/crt$i.o" "$src/x86-mes/crt$i.c" \
            >"$bdir/stage-crt$i.log" 2>&1 || { echo "stage crt$i FAIL"; cat "$bdir/stage-crt$i.log" >&2; exit 1; }
    done
    run -c $STAGE_CPPFLAGS -o "$st/libc.o" "$src/libc.c" \
        >"$bdir/stage-libc.log" 2>&1 || { echo "stage libc FAIL"; tail -20 "$bdir/stage-libc.log" >&2; exit 1; }
    run -ar cr "$st/lib/libc.a" "$st/libc.o" >>"$bdir/stage-libc.log" 2>&1
    run -c $STAGE_CPPFLAGS -o "$st/libtcc1.o" "$src/libtcc1.c" \
        >"$bdir/stage-libtcc1.log" 2>&1 || { echo "stage libtcc1 FAIL"; tail -20 "$bdir/stage-libtcc1.log" >&2; exit 1; }
    # libtcc1.a at stage root (with -B, tcc looks for TCC_LIBTCC1_MES under {B}/
    # directly) AND under lib/tcc for the installed layout.
    run -ar cr "$st/libtcc1.a" "$st/libtcc1.o" >>"$bdir/stage-libtcc1.log" 2>&1
    cp -f "$st/libtcc1.a" "$st/libtcc1-mes.a"
    cp -f "$st/libtcc1.a" "$st/lib/tcc/libtcc1.a"
    cp -f "$st/libtcc1.a" "$st/lib/tcc/libtcc1-mes.a"
    echo "stage_tcc: wrote $st/{lib/{crt1.o,crti.o,crtn.o,libc.a},libtcc1.a}" >&2
}

# ---- hello gate: compile+run hello.c, expect exit 42 (docs/mes-bootstrap.md) --
hello_gate() {
    thetcc=$1
    st="$bdir/stage"
    [ -d "$st" ] || { echo "hello_gate: stage first (build-tcc.sh stage $thetcc)" >&2; exit 1; }
    hc="$bdir/hello.c"
    cat > "$hc" <<'EOF'
#include <stdio.h>
int main (int argc, char **argv)
{
  puts ("Hello, tcc-mes!");
  return 42;
}
EOF
    ( cd "$repo" && "$thetcc" -B "$st" -I third_party/mes/include \
        -L "$st/lib" -o "$bdir/hello" "$hc" ) \
        >"$bdir/hello-compile.log" 2>&1 \
        || { echo "hello: COMPILE FAIL"; tail -20 "$bdir/hello-compile.log" >&2; exit 1; }
    # exit 42 is the SUCCESS code — guard the capture from `set -e`.
    rc=0; out=$("$bdir/hello" 2>&1) || rc=$?
    echo "hello: output='$out' exit=$rc"
    [ "$rc" = 42 ] || { echo "hello: FAIL (want exit 42, got $rc)" >&2; exit 1; }
    echo "hello: OK (exit 42)"
}

# ---- self-host boot chain (docs/mes-bootstrap.md) ----------------------------
# boot N: TCC recompiles all 10 units + links tcc-boot<n>, driven by the same
# invocations boot.sh uses, with our explicit -B/-L/-I and the stage libc.
# The BOOT_CPPFLAGS advance per level exactly as boot.sh does.
# Emits one token per line (so IFS=newline splitting keeps them as argv words).
# BOOTSTRAP=1 already comes from tcc_defines; boot_flags adds only the per-level
# HAVE_* switches.
boot_flags() {
    case $1 in
        0) printf -- '-D\nHAVE_LONG_LONG_STUB=1\n-D\nHAVE_SETJMP=1\n' ;;
        1) printf -- '-D\nHAVE_BITFIELD=1\n-D\nHAVE_LONG_LONG=1\n-D\nHAVE_SETJMP=1\n' ;;
        2) printf -- '-D\nHAVE_BITFIELD=1\n-D\nHAVE_FLOAT_STUB=1\n-D\nHAVE_LONG_LONG=1\n-D\nHAVE_SETJMP=1\n' ;;
        *) printf -- '-D\nHAVE_BITFIELD=1\n-D\nHAVE_FLOAT=1\n-D\nHAVE_LONG_LONG=1\n-D\nHAVE_SETJMP=1\n' ;;
    esac
}
# boot_one THETCC LEVEL OUT — compile 10 units with THETCC at boot LEVEL and link OUT
boot_one() {
    thetcc=$1; level=$2; out=$3
    st="$bdir/stage"
    bdirlvl="$bdir/boot$level"; rm -rf "$bdirlvl"; mkdir -p "$bdirlvl"
    # Assemble the -D block (boot flags + fixed CONFIG defines) as positional
    # params so the quoted CONFIG_TCC_* values survive as single argv words.
    _oldifs=$IFS; IFS='
'; set -- $(boot_flags "$level") $(tcc_defines); IFS=$_oldifs
    objs=""
    for u in $TCC_UNITS; do
        ( cd "$repo" && "$thetcc" -c "$@" \
            -I third_party/tinycc -I build/tcc/include \
            -I third_party/mes/include -I third_party/mes/lib \
            -o "$bdirlvl/$u.o" "third_party/tinycc/$u.c" ) \
            >"$bdirlvl/$u.log" 2>&1 \
            || { echo "boot$level: $u.c FAIL"; tail -15 "$bdirlvl/$u.log" >&2; return 1; }
        objs="$objs $bdirlvl/$u.o"
    done
    ( cd "$repo" && "$thetcc" -static -o "$out" "$@" \
        -B "$st" -L "$st/lib" $objs ) \
        >"$bdirlvl/link.log" 2>&1 \
        || { echo "boot$level: link FAIL"; tail -20 "$bdirlvl/link.log" >&2; return 1; }
    chmod +x "$out"
    echo "boot$level: $out ($(wc -c <"$out") B)"
    # boot.sh's REBUILD_LIBC tail: each freshly-built boot tcc re-stages crt +
    # libtcc1 (with -D HAVE_FLOAT=1) for the NEXT level to link against — this is
    # where the long-double runtime helpers (__floatundixf etc.) that HAVE_FLOAT
    # codegen needs come from.  Rebuild crt1/i/n + libtcc1 in-place in the stage.
    restage_boot "$out" "$level" || { echo "boot$level: restage FAIL" >&2; return 1; }
}
# restage_boot TCC LEVEL — rebuild crt{1,i,n}.o + libtcc1.a (HAVE_FLOAT=1) with
# TCC into the stage, so the next boot level links the float runtime helpers.
restage_boot() {
    thetcc=$1; level=$2
    st="$bdir/stage"; src="$bdir/src"
    run() { ( cd "$repo" && "$thetcc" "$@" ); }
    for i in 1 i n; do
        run -c -static -nostdlib -nostdinc $STAGE_CPPFLAGS \
            -o "$st/lib/crt$i.o" "$src/x86-mes/crt$i.c" \
            >"$bdir/boot$level-crt$i.log" 2>&1 || return 1
    done
    run -c -D HAVE_FLOAT=1 $STAGE_CPPFLAGS \
        -o "$bdir/boot$level-libtcc1.o" "$src/libtcc1.c" \
        >"$bdir/boot$level-libtcc1.log" 2>&1 || return 1
    run -ar cr "$st/libtcc1.a" "$bdir/boot$level-libtcc1.o" >>"$bdir/boot$level-libtcc1.log" 2>&1 || return 1
    cp -f "$st/libtcc1.a" "$st/libtcc1-mes.a"
    cp -f "$st/libtcc1.a" "$st/lib/tcc/libtcc1.a"
    cp -f "$st/libtcc1.a" "$st/lib/tcc/libtcc1-mes.a"
}
boot_chain() {
    seed=$1; last=${2-6}
    cur="$seed"; lvl=0
    while [ "$lvl" -le "$last" ]; do
        out="$bdir/tcc-boot$lvl"
        boot_one "$cur" "$lvl" "$out" || return 1
        cur="$out"; lvl=$((lvl + 1))
    done
    # upstream's self-host fixpoint check: boot5 == boot6.
    if [ "$last" -ge 6 ] && [ -f "$bdir/tcc-boot5" ] && [ -f "$bdir/tcc-boot6" ]; then
        if cmp -s "$bdir/tcc-boot5" "$bdir/tcc-boot6"; then
            echo "boot: SELF-HOST FIXPOINT — tcc-boot5 == tcc-boot6"
        else
            echo "boot: FAIL — tcc-boot5 != tcc-boot6: $(cmp "$bdir/tcc-boot5" "$bdir/tcc-boot6" 2>&1)" >&2
            return 1
        fi
    fi
}

# ---- T0: reference tcc under bin/mes-m2 + hashes -----------------------------
do_t0() {
    jobs=${1-16}
    need_tools
    echo "==================== T0: reference tcc under bin/mes-m2 ===================="
    echo "T0: build libc+tcc (host bin/mes-m2) ..."
    build_libc "$jobs"
    echo "T0: sweep 10 tcc units under bin/mes-m2 ..."
    refset="$bdir/ref"; rm -rf "$refset"; mkdir -p "$refset"
    sweep "$repo/bin/mes-m2" "$refset" "$jobs"
    fail=0
    for u in $TCC_UNITS; do [ -f "$refset/$u.s" ] || { echo "T0: MISSING $u.s"; fail=1; }; done
    [ "$fail" = 0 ] || { echo "T0: reference sweep incomplete" >&2; exit 1; }
    echo "T0: link tcc-mes.ref ..."
    link_tcc "$refset" "$bdir/tcc-mes.ref"
    ver=$( ( cd "$repo" && "$bdir/tcc-mes.ref" -vv ) 2>&1 | head -1 || true )
    echo "T0: version: $ver"
    case "$ver" in *"0.9.27 (i386 Linux)"*) : ;; *) echo "T0: unexpected version string" >&2; exit 1 ;; esac
    echo "T0: stage libc + hello gate ..."
    stage_tcc "$bdir/tcc-mes.ref"
    hello_gate "$bdir/tcc-mes.ref"
    echo "T0: self-host boot chain (tcc-mes.ref -> boot6) ..."
    boot_chain "$bdir/tcc-mes.ref" 6
    # Commit the reference hashes: 10 .s + tcc-mes.ref + tcc-boot5.
    mkdir -p "$refdir"
    ( cd "$refset" && sha256sum $(for u in $TCC_UNITS; do echo "$u.s"; done) ) > "$refdir/t0.sha256"
    ( cd "$bdir" && sha256sum tcc-mes.ref tcc-boot5 ) >> "$refdir/t0.sha256"
    echo "T0: wrote $refdir/t0.sha256"
    echo "T0: DONE (reference tcc builds, version OK, hello exit 42, self-host fixpoint)"
}

# ---- T1 verify: offline qmes sweep vs committed .s hashes --------------------
do_verify() {
    jobs=${1-8}
    [ -x "$repo/qmes.elf" ] || { echo "verify: build qmes first (make qmes)" >&2; exit 2; }
    [ -f "$refdir/t0.sha256" ] || { echo "verify: missing $refdir/t0.sha256 (run t0 first)" >&2; exit 2; }
    out="$bdir/verify"; rm -rf "$out"; mkdir -p "$out"
    echo "verify: sweep 10 tcc units under qmes (interpreted, slow) ..."
    sweep "$repo/qmes.elf" "$out" "$jobs"
    # Check only the .s lines from the manifest (drop tcc-mes.ref/tcc-boot5).
    grep '\.s$' "$refdir/t0.sha256" > "$out/t1.sha256"
    ( cd "$out" && sha256sum -c t1.sha256 ) \
        && echo "verify: T1 OK — all 10 tcc .s byte-identical to the committed reference" \
        || { echo "verify: T1 FAILED — qmes MesCC output diverged" >&2; exit 1; }
}

# ---- T1/T2/T3 full: qmes vs reference ----------------------------------------
do_fixpoint() {
    jobs=${1-16}
    need_tools
    [ -x "$repo/qmes.elf" ] || { echo "fixpoint: build qmes first (make qmes)" >&2; exit 2; }

    echo "==================== T1: qmes compiles the 10 tcc units ===================="
    refset="$bdir/ref"; qset="$bdir/qmes"
    if [ ! -f "$refset/tcc.s" ]; then
        echo "T1: no reference sweep found — building libc+tcc and reference sweep first ..."
        build_libc "$jobs"
        rm -rf "$refset"; mkdir -p "$refset"; sweep "$repo/bin/mes-m2" "$refset" "$jobs"
    fi
    rm -rf "$qset"; mkdir -p "$qset"
    echo "T1: sweep 10 tcc units under ./qmes.elf (interpreted — slow) ..."
    sweep "$repo/qmes.elf" "$qset" "$jobs"
    pass=0; div=0
    for u in $TCC_UNITS; do
        if cmp -s "$qset/$u.s" "$refset/$u.s"; then pass=$((pass + 1))
        else echo "  T1 DIVERGE $u.s: $(cmp "$qset/$u.s" "$refset/$u.s" 2>&1)"; div=$((div + 1)); fi
    done
    echo "T1: $pass/10 byte-identical, $div diverge"
    [ "$div" = 0 ] || { echo "T1 FAILED ($div diverge)" >&2; exit 1; }

    echo "==================== T2: link + run from the qmes path ===================="
    [ -f "$adir/libc+tcc.s" ] || build_libc "$jobs"
    link_tcc "$qset" "$bdir/tcc-mes.qmes"
    if [ -f "$bdir/tcc-mes.ref" ] && cmp -s "$bdir/tcc-mes.ref" "$bdir/tcc-mes.qmes"; then
        echo "T2: LINKED BINARIES BYTE-IDENTICAL  sha256=$(sha256sum "$bdir/tcc-mes.qmes" | awk '{print $1}')"
    elif [ -f "$bdir/tcc-mes.ref" ]; then
        echo "T2 FAILED: tcc-mes.ref != tcc-mes.qmes" >&2; exit 1
    fi
    stage_tcc "$bdir/tcc-mes.qmes"
    hello_gate "$bdir/tcc-mes.qmes"

    echo "==================== T3: tcc self-host fixpoint from the qmes tcc ===================="
    boot_chain "$bdir/tcc-mes.qmes" 6
    echo "============================================================================"
    echo "TCC RUNG (i386): T1 10/10 | T2 byte-identical tcc | T3 self-host fixpoint"
}

# Verbs needing mescc-tools self-enter the nix shell before doing anything.
case "${1-}" in
    libc|link|stage|hello|boot|t0|fixpoint) enter_nix_if_needed "$@" ;;
esac

case "${1-}" in
    units)   for u in $TCC_UNITS; do echo "$u"; done ;;
    libc)    build_libc "${2-16}" ;;
    compile) sweep "$2" "$3" "${4-8}" ;;
    link)    link_tcc "$2" "$3" ;;
    stage)   stage_tcc "$2" ;;
    hello)   hello_gate "$2" ;;
    boot)    boot_chain "$2" "${3-6}" ;;
    t0)      do_t0 "${2-16}" ;;
    verify)  do_verify "${2-8}" ;;
    fixpoint) do_fixpoint "${2-16}" ;;
    *) echo "usage: $0 {units|libc [JOBS]|compile HOST OUTDIR [JOBS]|link SDIR OUT|stage TCC|hello TCC|boot TCC [N]|t0 [JOBS]|verify [JOBS]|fixpoint [JOBS]}" >&2; exit 2 ;;
esac
