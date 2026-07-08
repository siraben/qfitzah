#!/bin/sh
# record-mes-references.sh — capture reference behavior of bin/mes-m2 from the
# merged root (FD §5.4/§5.5, roadmap S0), for offline differential gates.
#
# Records, under tests/mes-references/:
#   help.out       mes --help          (usage banner)
#   version.out    mes --version
#   c-arith.out    mes -c '(display (+ 1 2))'
#   c-version.out  mes -c '(display %version)'
#   s-stdin.out    (echo ... | mes -s /dev/stdin)
#   B0.out B1.out B2.out   the boot-5 cut gates (MES_BOOT=<cut>)
# plus <name>.status files holding each exit status.
#
# Then writes a sha256 manifest tests/mes-references.sha256 so later stages can
# diff qmes output against these bytes without re-running the reference.
#
# Usage: tools/record-mes-references.sh   (runs make-mesroot + gen-boot-cuts)
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

tools/make-mesroot.sh >/dev/null 2>&1
tools/gen-boot-cuts.sh >/dev/null 2>&1

mes=bin/mes-m2
out=tests/mes-references
rm -rf "$out"; mkdir -p "$out"

# deterministic environment (roadmap standing rules / determinism scrub).
run() {
  MES_PREFIX="$repo_root/build/mesroot" \
  MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=5000000 \
  LANG= LC_ALL= TZ=UTC MES_DEBUG=0 "$@"
}

record() { # record NAME  -- reads command from "$@" after NAME; stdin from </dev/null
  name=$1; shift
  st=0
  "$@" > "$out/$name.out" 2> "$out/$name.err" </dev/null || st=$?
  echo "$st" > "$out/$name.status"
}

record help    run "$mes" --help
record version run "$mes" --version
record c-arith run "$mes" -c '(display (+ 1 2))'
record c-version run "$mes" -c '(display %version)'

# -s from a real file (deterministic content).
printf '(display (+ 1 2))(newline)\n' > "$out/s-input.scm"
st=0
run "$mes" -s "$out/s-input.scm" > "$out/s-stdin.out" 2> "$out/s-stdin.err" </dev/null || st=$?
echo "$st" > "$out/s-stdin.status"

for g in B0 B1 B2; do
  st=0
  MES_BOOT="$g.scm" MES_PREFIX="$repo_root/build/mesroot" \
    MES_ARENA=20000000 MES_MAX_ARENA=20000000 MES_STACK=5000000 \
    LANG= LC_ALL= TZ=UTC MES_DEBUG=0 "$mes" \
    > "$out/$g.out" 2> "$out/$g.err" </dev/null || st=$?
  echo "$st" > "$out/$g.status"
done

( cd "$out" && sha256sum ./*.out ./*.status ) > tests/mes-references.sha256
echo "[record-mes-references] wrote $out and tests/mes-references.sha256" >&2
