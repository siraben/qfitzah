#!/bin/sh
# Build bootstrap/qmes.scm into qmes.elf via the qfitzah ladder.
#
#   scheme0.elf (seed-assembled) compiles sc1.scm -> sc1.elf
#   sc1.elf compiles rsc.scm -> rscA.elf   (the Stage 4 rsc compiler)
#   rscA.elf compiles (rsc-prelude ++ qmes.scm) -> qmes.qfasm
#   seed assembles (qfasm.qf1 ++ rsc-runtime.qf1 ++ qmes.qfasm) -> qmes.elf
#
# The Stage 2..4 toolchain (scheme0/sc1/rscA) is expensive to assemble, so it
# is cached under build/qmes/ and only rebuilt when its inputs change.  Only
# the final two steps (compile qmes.scm, assemble qmes.elf) run each time.
#
# Usage: tools/build-qmes.sh [qfitzah-path]   (default result/bin/qfitzah)
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
qfitzah=${1:-$repo_root/result/bin/qfitzah}
b="$repo_root/build/qmes"
mkdir -p "$b"

bootstrap="$repo_root/bootstrap"
QFASM="$bootstrap/qfasm.qf1"

need() { # need OUT IN...  -> true if OUT is missing or older than any IN
  out=$1; shift
  [ -f "$out" ] || return 0
  for f in "$@"; do [ "$f" -nt "$out" ] && return 0; done
  return 1
}

# --- Stage 2: scheme0.elf ---------------------------------------------------
if need "$b/scheme0.elf" "$QFASM" "$bootstrap/scheme0.qfasm"; then
  echo "[build-qmes] assembling scheme0.elf" >&2
  cat "$QFASM" "$bootstrap/scheme0.qfasm" | "$qfitzah" > "$b/scheme0.elf"
  chmod +x "$b/scheme0.elf"
fi

# --- Stage 3: sc1.elf -------------------------------------------------------
if need "$b/sc1.elf" "$b/scheme0.elf" "$bootstrap/sc1-reader.scm" \
        "$bootstrap/sc1.scm" "$bootstrap/sc1-runtime.qf1"; then
  echo "[build-qmes] compiling+assembling sc1.elf" >&2
  cat "$bootstrap/sc1-reader.scm" "$bootstrap/sc1.scm" \
      "$bootstrap/sc1-reader.scm" "$bootstrap/sc1.scm" \
    | "$b/scheme0.elf" > "$b/sc1.qfasm"
  cat "$QFASM" "$bootstrap/sc1-runtime.qf1" "$b/sc1.qfasm" \
    | "$qfitzah" > "$b/sc1.elf"
  chmod +x "$b/sc1.elf"
fi

# --- Stage 4: rscA.elf ------------------------------------------------------
if need "$b/rscA.elf" "$b/sc1.elf" "$bootstrap/sc1-reader.scm" \
        "$bootstrap/rsc.scm" "$bootstrap/rsc-runtime.qf1"; then
  echo "[build-qmes] compiling+assembling rscA.elf" >&2
  cat "$bootstrap/sc1-reader.scm" "$bootstrap/rsc.scm" \
    | "$b/sc1.elf" > "$b/rscA.qfasm"
  cat "$QFASM" "$bootstrap/rsc-runtime.qf1" "$b/rscA.qfasm" \
    | "$qfitzah" > "$b/rscA.elf"
  chmod +x "$b/rscA.elf"
fi

# --- asm.elf: the native assembler (replaces the seed for big programs) ------
# bootstrap/asm.scm is compiled by rscA.elf, then assembled ONCE through the
# seed (~39k instrs, well under the seed's ceiling) into asm.elf.  Thereafter it
# assembles arbitrarily large programs (full qmes, MesCC output) in O(program)
# memory -- the seed only ever assembles scheme0 and this one-time bootstrap.
ASM_RUNTIME="$bootstrap/asm-runtime.flat"
if need "$b/asm.elf" "$b/rscA.elf" "$bootstrap/asm.scm" "$bootstrap/rsc-runtime.qf1"; then
  echo "[build-qmes] compiling+assembling asm.elf" >&2
  cat "$bootstrap/rsc-prelude.scm" "$bootstrap/asm.scm" \
    | "$b/rscA.elf" > "$b/asm.qfasm"
  cat "$QFASM" "$bootstrap/rsc-runtime.qf1" "$b/asm.qfasm" \
    | "$qfitzah" > "$b/asm.elf"
  chmod +x "$b/asm.elf"
fi

# --- qmes: compile then assemble -------------------------------------------
# The assembly step uses asm.elf by default; set USE_SEED_ASM=1 to fall back to
# the seed (both produce byte-identical output).
echo "[build-qmes] compiling qmes.scm -> qmes.qfasm" >&2
# The trailing (qmain) call lives in bootstrap/qmes-main.scm so that the 64-bit
# variant (tools/build-qmes64.sh) can splice bootstrap/qmes-w64.scm before it.
# cat qmes.scm + qmes-main.scm is byte-identical to the pre-split qmes.scm.
cat "$bootstrap/rsc-prelude.scm" "$bootstrap/qmes.scm" "$bootstrap/qmes-main.scm" \
  | "$b/rscA.elf" > "$b/qmes.qfasm"
if [ "${USE_SEED_ASM:-0}" = "1" ]; then
  echo "[build-qmes] assembling qmes.qfasm -> qmes.elf (seed)" >&2
  cat "$QFASM" "$bootstrap/rsc-runtime.qf1" "$b/qmes.qfasm" \
    | "$qfitzah" > "$repo_root/qmes.elf"
else
  echo "[build-qmes] assembling qmes.qfasm -> qmes.elf (asm.elf)" >&2
  "$b/asm.elf" "$ASM_RUNTIME" < "$b/qmes.qfasm" > "$repo_root/qmes.elf"
fi
chmod +x "$repo_root/qmes.elf"
echo "[build-qmes] wrote $repo_root/qmes.elf" >&2
