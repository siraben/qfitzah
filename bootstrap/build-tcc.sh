#!/usr/bin/env bash
# Complete source-only recipe after the explicitly trusted qfitzah seed.
# Staged for end-to-end verification; see BOOTSTRAP-PLAN.md for current evidence.
set -euo pipefail
if [[ $# != 5 ]]; then
  echo "usage: $0 SEED VERIFIED_MES_SOURCE VERIFIED_NYACC_SOURCE VERIFIED_TCC_SOURCE NEW_DIRECTORY" >&2
  exit 2
fi
seed=$(realpath "$1")
mes=$(realpath "$2")
nyacc=$(realpath "$3")
tcc=$(realpath "$4")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$5"
out=$(realpath "$5")
# Never execute scripts while the checkout is being edited.
mkdir "$out/recipe"
cp -RL "$root/bootstrap" "$root/tests" "$out/recipe/"
b=$out/recipe/bootstrap
t=$out/recipe/tests
bash "$t/upstream-preparation.sh" "$mes" "$nyacc" "$tcc"
cp "$seed" "$out/qfitzah"
chmod +x "$out/qfitzah"
seed=$out/qfitzah
sha256sum "$seed" > "$out/seed.sha256"
bash "$t/bootstrap-artifacts.sh" "$seed" "$out/stages" "$out/recipe"
compiler=$out/stages/rscB.elf
cat "$b/sc1-reader.scm" "$b/rsc.scm" | "$compiler" > "$out/stages/rscC.qfasm"
cmp "$out/stages/rscB.qfasm" "$out/stages/rscC.qfasm"
bash "$b/assemble.sh" "$seed" rsc "$out/stages/rscC.qfasm" > "$out/stages/rscC.elf"
chmod +x "$out/stages/rscC.elf"
cmp "$compiler" "$out/stages/rscC.elf"
bash "$b/build-mes-host.sh" "$seed" "$compiler" "$out/host"
bash "$b/build-m1.sh" "$seed" "$compiler" "$out/m1"
host=$out/host/mes-host
link=$out/m1/m1-link
bash "$b/build-mescc-normalizer.sh" "$seed" "$compiler" "$host" "$mes" "$out/normalizer"
normalizer=$out/normalizer/normalize
export QFITZAH_MESCC_NORMALIZER=$normalizer
bash "$b/regenerate-nyacc.sh" "$host" "$mes" "$nyacc" "$out/nyacc"
bash "$t/nyacc-generated.sh" "$host" "$mes" "$nyacc" "$out/nyacc"
bash "$t/mes-upstream.sh" "$host" "$mes"
bash "$t/mescc-normalizer.sh" "$host" "$mes" "$out/nyacc" "$normalizer"
bash "$t/mescc-trace.sh" "$host" "$mes" "$out/nyacc"
bash "$t/mescc-c.sh" "$host" "$link" "$mes" "$out/nyacc"
bash "$b/build-mes-libc.sh" mini "$host" "$mes" "$out/nyacc" "$out/libc-mini"
bash "$t/mescc-libc-mini.sh" "$host" "$link" "$mes" "$out/nyacc" "$out/libc-mini"
bash "$b/build-mes-libc.sh" tcc "$host" "$mes" "$out/nyacc" "$out/libc-tcc"
bash "$b/build-tcc-mes.sh" "$host" "$link" "$mes" "$out/nyacc" "$tcc" "$out/libc-tcc" "$out/tcc"
bash "$b/rebuild-tcc.sh" "$out/tcc" "$out/libc-tcc"
bash "$t/tcc.sh" "$out/tcc/tcc"
sha256sum "$compiler" "$host" "$link" "$normalizer" "$out/tcc/tcc" > "$out/toolchain.sha256"
printf 'ok - source bootstrap through TCC: %s\n' "$out/tcc/tcc"
