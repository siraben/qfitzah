# tools/lib/mescc.sh — shared MesCC driver for the fixpoint/tcc harnesses.
#
# All the fixpoint scripts run GNU Mes's MesCC under a scrubbed, byte-pinned
# environment (the determinism contract: env -i, LANG=, %version pinned, fixed
# MES_ARENA/STACK, MES_PREFIX = the merged mesroot, run from repo root so any
# path reaching the .s is host-independent).  That scrub boilerplate used to be
# copy-pasted into each caller; it lives here once instead.
#
# This helper encapsulates ONLY the invocation shape.  Every byte-affecting
# VALUE is supplied by the caller as an environment variable, so the resulting
# command line is identical to the hand-written form each script used before:
#
#   MES_PREFIX, MES_SRCDEST, MES_MODULEDIR   — required (the mesroot + module dir)
#   MES_ARENA, MES_MAX_ARENA, MES_STACK      — required (arena/stack policy)
#   MES_ARCH_PIN                             — optional; when set (e.g. x86_64),
#                                              passes `%arch=$MES_ARCH_PIN`
#   MES_SCM                                  — optional; the mescc.scm path
#                                              (default third_party/mes/module/mescc.scm)
#
# Usage (from a subshell already `cd`'d into the repo root):
#   mescc_run HOST -- <mescc args...>
# e.g. mescc_run "$host" -- -S -m 32 --arch=x86 -o out.s in.c
#
# The caller passes PATH through unchanged (env -i drops it otherwise).

# mescc_run HOST [mescc args...] — exec the pinned MesCC driver.
mescc_run() {
    _mr_host=$1; shift
    _mr_scm=${MES_SCM-third_party/mes/module/mescc.scm}
    if [ -n "${MES_ARCH_PIN-}" ]; then
        exec env -i \
            PATH="$PATH" \
            LANG= \
            MES_DEBUG=0 \
            %version=0.27.1 \
            %arch="$MES_ARCH_PIN" \
            MES_ARENA="$MES_ARENA" \
            MES_MAX_ARENA="$MES_MAX_ARENA" \
            MES_STACK="$MES_STACK" \
            MES_PREFIX="$MES_PREFIX" \
            srcdest="$MES_SRCDEST" \
            GUILE_LOAD_PATH="$MES_MODULEDIR" \
            "$_mr_host" \
                --no-auto-compile \
                -e main \
                "$_mr_scm" \
                "$@"
    else
        exec env -i \
            PATH="$PATH" \
            LANG= \
            MES_DEBUG=0 \
            %version=0.27.1 \
            MES_ARENA="$MES_ARENA" \
            MES_MAX_ARENA="$MES_MAX_ARENA" \
            MES_STACK="$MES_STACK" \
            MES_PREFIX="$MES_PREFIX" \
            srcdest="$MES_SRCDEST" \
            GUILE_LOAD_PATH="$MES_MODULEDIR" \
            "$_mr_host" \
                --no-auto-compile \
                -e main \
                "$_mr_scm" \
                "$@"
    fi
}
