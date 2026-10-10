#!/usr/bin/env bash
# Complete fresh qfitzah -> stage0/M2 -> Blynn/HCC -> TinyCC acceptance recipe.
set -euo pipefail
# Discard inherited compiler, source-path and runtime-generation overrides.
if [[ ${1:-} != --internal-clean ]]; then
  exec env -i PATH="$PATH" HOME="${HOME:-/}" LC_ALL=C TZ=UTC \
    bash "$(realpath "$0")" --internal-clean "$@"
fi
shift
if (( $# != 3 )); then
  echo "usage: $0 TRUSTED_SEED SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
clock_ticks() {
  local uptime rest
  read -r uptime rest < /proc/uptime
  printf '%s\n' "${uptime/./}"
}
start=$(clock_ticks)
limit_seconds=1800
seed=$(realpath "$1")
cache=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$3"
out=$(realpath "$3")
active=
build_complete=false
finish() {
  local status=$? end elapsed accepted=false
  end=$(clock_ticks)
  elapsed=$((end-start))
  if [[ -n $active ]]; then
    printf '%s\t%d\tfailed\t%d\n' "$active" "$((end-phase_start))" "$status" >> "$out/phases.tsv"
  fi
  if [[ $build_complete == true && $status == 0 ]]; then
    if (( elapsed < limit_seconds * 100 )); then
      accepted=true
      echo 'ok - fresh complete qfitzah -> Blynn/HCC -> TCC recipe under 30 minutes'
    else
      status=1
      echo 'Build and tests finished, but the 30-minute target was missed.' >&2
    fi
  fi
  printf '{"complete":%s,"fresh_recipe_pass":%s,"exit":%d,"elapsed_centiseconds":%d,"clock":"/proc/uptime","limit_seconds":%d}\n' \
    "$build_complete" "$accepted" "$status" "$elapsed" "$limit_seconds" > "$out/timing.json"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
phase() {
  active=$1
  shift
  phase_start=$(clock_ticks)
  echo "BEGIN $active"
  "$@"
  printf '%s\t%d\tpassed\t0\n' "$active" "$(($(clock_ticks)-phase_start))" >> "$out/phases.tsv"
  echo "END $active"
  active=
}
printf 'phase\telapsed_centiseconds\tstatus\texit\n' > "$out/phases.tsv"
mkdir "$out/recipe" "$out/guard" "$out/tmp"
export TMPDIR="$out/tmp"
cp -RL "$root/bootstrap" "$root/tests" "$out/recipe/"
# Every component reads this one snapshot; no private recipe copies can drift.
chmod -R a-w "$out/recipe"
b=$out/recipe/bootstrap
cp "$seed" "$out/qfitzah"
chmod 555 "$out/qfitzah"
(cd "$out" && sha256sum -c "$b/blynn/seed.sha256")
(cd "$out/recipe" && find bootstrap tests -type f -print0 | sort -z | xargs -0 sha256sum) > "$out/recipe.sha256"
for name in cc gcc clang c++ g++ clang++ cpp as nasm yasm ld ar llvm-as llvm-mc llvm-ar \
  tcc mes mescc ghc runghc guile scheme chezscheme racket \
  M2-Mesoplanet M2-Planet M1 hex2 kaem blood-elf hcpp hcc1 hcc-m1; do
  cp "$b/blynn/deny-compiler.sh" "$out/guard/$name"
  chmod 555 "$out/guard/$name"
done
export PATH="$out/guard:$PATH"
phase sources bash "$b/blynn/fetch.sh" "$cache"
phase tools bash "$b/build-blynn-tools.sh" "$out/qfitzah" "$cache" "$out/tools"
for lineage in A B; do
  phase "singularity-$lineage" bash "$b/build-singularity.sh" "$out/qfitzah" \
    "$out/tools/stages/rsc$lineage.elf" "$out/singularity-$lineage"
  phase "singularity-tests-$lineage" bash "$out/recipe/tests/singularity.sh" \
    "$out/singularity-$lineage/singularity"
done
cmp "$out/singularity-A/singularity.qfasm" "$out/singularity-B/singularity.qfasm"
cmp "$out/singularity-A/singularity" "$out/singularity-B/singularity"
phase blynn-root bash "$b/build-blynn-root.sh" "$out/tools" \
  "$out/singularity-B/singularity" "$cache" "$out/blynn-root"
phase blynn-hcc bash "$b/build-blynn-hcc.sh" "$out/tools" "$out/blynn-root" "$cache" "$out/blynn-hcc"
phase tcc bash "$b/build-blynn-tcc.sh" "$out/tools" "$out/blynn-hcc" "$cache" "$out/tcc"
(cd "$out/recipe" && sha256sum -c "$out/recipe.sha256" > "$out/recipe-verified.log")
sha256sum "$out/qfitzah" "$out/tools/bin/"* "$out/blynn-root/bin/"* \
  "$out/blynn-hcc/hcc/bin/"* "$out/tcc/tcc/bin/"* \
  "$out/tcc/final/bin/tcc" "$out/tcc/final/lib/"* > "$out/toolchain.sha256"
build_complete=true
