#!/bin/sh
# mescc-fixpoint.sh — the S6 F1/F2/F3 fixpoint driver for GNU Mes on qfitzah.
#
# F1 (path-independent MesCC assembly): for every compile unit in the MesCC
# build of the `mes` binary (mes_SOURCES, build-aux/configure-lib.sh:454), run
# `mescc -S` under a chosen Scheme host and emit the .s (M1 text).  The caller
# runs it under BOTH ./qmes.elf and bin/mes-m2 with byte-identical env + an
# IDENTICAL -o path, then cmp's the two .s trees.  Byte-identity across hosts is
# F1 — the core claim that the interpreter (qmes vs M2-Planet mes-m2) does not
# affect MesCC's output.
#
# The compile-unit list and per-file flags are transcribed from the real MesCC
# build path:
#   * mes_SOURCES        build-aux/configure-lib.sh:454-475  (20 src/*.c units,
#                        each a SEPARATE translation unit — NOT an amalgamation)
#   * AM_CPPFLAGS        build-aux/cflags.sh  (-D HAVE_CONFIG_H=1 -I include
#                        -I include/$mes_kernel/$mes_cpu)  with our synthesized
#                        <mes/config.h> under build/include taking precedence
#                        (the tree ships no include/mes/config.h).
#   * -S -m 32 --arch=x86    compile-only, i386.
#
# Determinism contract (mes-bootstrap-plan §5): env -i, LANG=, %version pinned,
# fixed MES_ARENA/STACK, MES_PREFIX = the merged mesroot, run from repo root so
# any path string reaching the .s (notably the -o label MesCC embeds verbatim)
# is host-independent.
#
# Usage:
#   tools/mescc-fixpoint.sh compile HOST OUTDIR [JOBS]   # F1/F3 sweep one host
#   tools/mescc-fixpoint.sh units                        # print the unit list
#
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tp="$repo_root/third_party/mes"
root="$repo_root/build/mesroot"
moduledir="$root/mes/module"

# The MesCC compile units for the `mes` binary (configure-lib.sh mes_SOURCES).
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
    [ -d "$moduledir/nyacc/lang/c99" ] || "$repo_root/tools/make-mesroot.sh" >/dev/null
    cfg="$repo_root/build/include/mes/config.h"
    if [ ! -f "$cfg" ]; then
        mkdir -p "$repo_root/build/include/mes"
        ver=$(sed -n 's/^VERSION=//p' "$tp/configure.sh" | head -1)
        printf '#undef SYSTEM_LIBC\n#define MES_VERSION "%s"\n' "${ver:-0.27.1}" > "$cfg"
    fi
    # configure.sh:268-270 copies the kernel/cpu-specific headers into
    # include/arch/ so that <arch/signal.h> etc. resolve.  We keep third_party
    # pristine and mirror them under build/include/arch/ (on -I build/include).
    if [ ! -e "$repo_root/build/include/arch/signal.h" ]; then
        mkdir -p "$repo_root/build/include/arch"
        for h in kernel-stat.h signal.h syscall.h; do
            ln -sf "$tp/include/linux/x86/$h" "$repo_root/build/include/arch/$h"
        done
    fi
}

# compile_one HOST REL_INPUT.c REL_OUTPUT.s  — one MesCC -S invocation.
# All paths are REPO-RELATIVE and the command runs from repo_root, so the -o
# string MesCC embeds verbatim as `_string_<path>_N` labels (and any input path
# reaching the .s) is repo-relative and thus host- and machine-independent —
# the committed reference hashes are portable to any checkout.
compile_one() {
    _host=$1; _in=$2; _out=$3
    mkdir -p "$repo_root/$(dirname "$_out")"
    ( cd "$repo_root" && exec env -i \
        PATH="$PATH" \
        LANG= \
        MES_DEBUG=0 \
        %version=0.27.1 \
        MES_ARENA="${MES_ARENA-20000000}" \
        MES_MAX_ARENA="${MES_MAX_ARENA-20000000}" \
        MES_STACK="${MES_STACK-5000000}" \
        MES_PREFIX="$root" \
        srcdest="$tp/" \
        GUILE_LOAD_PATH="$moduledir" \
        "$_host" \
            --no-auto-compile \
            -e main \
            third_party/mes/module/mescc.scm \
            -- \
            -S -m 32 --arch=x86 \
            -D HAVE_CONFIG_H=1 \
            -I build/include \
            -I third_party/mes/include \
            -o "$_out" \
            "$_in" )
}

case "${1-}" in
    units)
        for u in $UNITS; do echo "$u"; done
        ;;
    compile)
        host=$2; outdir=$3; jobs=${4-8}
        ensure_env
        mkdir -p "$outdir"
        # Resolve host to an absolute path (env -i drops cwd-relative lookups).
        case "$host" in
            /*) : ;;
            *)  host="$repo_root/$host" ;;
        esac
        # CRITICAL: MesCC embeds the -o path verbatim as `_string_<path>_N`
        # labels in the .s.  For F1/F3 byte-identity across hosts, every host
        # MUST compile with the SAME -o string.  We therefore compile each unit
        # to a canonical, host-independent path under build/fixpoint/canon/ and
        # then move the result into the per-host $outdir.  (Within a sweep each
        # unit has a distinct name, so parallel jobs never collide on canon/.)
        canon_rel="build/fixpoint/canon"          # repo-relative -o label
        mkdir -p "$repo_root/$canon_rel"
        outdir_abs=$(cd "$outdir" && pwd)
        pids=""
        n=0
        for u in $UNITS; do
            base=$(echo "$u" | sed -e 's,/,-,g' -e 's,\.c$,,')
            cout="$canon_rel/$base.s"                # relative (for -o label)
            out="$outdir_abs/$base.s"
            log="$outdir_abs/$base.log"
            ( if compile_one "$host" "third_party/mes/$u" "$cout" >"$log" 2>&1; then
                  mv -f "$repo_root/$cout" "$out"
                  echo "done $u"
              else
                  rm -f "$repo_root/$cout"
                  echo "FAIL $u (see $log)"
              fi ) &
            pids="$pids $!"
            n=$((n + 1))
            # throttle to $jobs concurrent
            while [ "$(jobs -r 2>/dev/null | wc -l)" -ge "$jobs" ]; do wait -n 2>/dev/null || break; done
        done
        wait
        echo "compile: $n units -> $outdir"
        ;;
    verify)
        # Offline F1 gate: sweep qmes only and check every unit against the
        # committed reference hashes (tests/mescc-references/fixpoint/f1.sha256).
        # Needs only ./qmes.elf + the vendored nyacc/mescc — no M2-Planet, no
        # mes-m2.  This is the checkable-anywhere form of the F1 claim.
        jobs=${2-8}
        refhash="$repo_root/tests/mescc-references/fixpoint/f1.sha256"
        [ -f "$refhash" ] || { echo "verify: missing $refhash" >&2; exit 2; }
        [ -x "$repo_root/qmes.elf" ] || { echo "verify: build qmes first (make qmes)" >&2; exit 2; }
        out="$repo_root/build/fixpoint/verify"
        rm -rf "$out"; mkdir -p "$out"
        "$0" compile "$repo_root/qmes.elf" "$out" "$jobs" | grep -c '^done' >/dev/null
        ( cd "$out" && sha256sum -c "$refhash" ) || {
            echo "verify: F1 FAILED — qmes MesCC output diverged from the committed reference" >&2
            exit 1
        }
        echo "verify: F1 OK — all $(grep -c . "$refhash") mes_SOURCES units byte-identical to the reference"
        ;;
    f1)
        # Full F1: sweep BOTH hosts and cmp per unit.  Needs bin/mes-m2.
        jobs=${2-16}
        base="$repo_root/build/fixpoint"
        rm -rf "$base/f1-ref" "$base/f1-qmes"; mkdir -p "$base/f1-ref" "$base/f1-qmes"
        echo "F1: sweep bin/mes-m2 ..." >&2
        "$0" compile "$repo_root/bin/mes-m2" "$base/f1-ref" "$jobs" >/dev/null
        echo "F1: sweep ./qmes.elf (interpreted — slow) ..." >&2
        "$0" compile "$repo_root/qmes.elf" "$base/f1-qmes" "$jobs" >/dev/null
        pass=0; div=0
        for u in $UNITS; do
            b=$(echo "$u" | sed -e 's,/,-,g' -e 's,\.c$,.s,')
            if cmp -s "$base/f1-qmes/$b" "$base/f1-ref/$b"; then
                pass=$((pass + 1))
            else
                echo "F1 DIVERGE $b: $(cmp "$base/f1-qmes/$b" "$base/f1-ref/$b" 2>&1)"
                div=$((div + 1))
            fi
        done
        echo "F1: $pass/20 byte-identical, $div diverge"
        [ "$div" = 0 ]
        ;;
    *)
        echo "usage: $0 {units | compile HOST OUTDIR [JOBS] | verify [JOBS] | f1 [JOBS]}" >&2
        exit 2
        ;;
esac
