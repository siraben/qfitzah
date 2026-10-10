#!/usr/bin/env bash
# qfitzah -> Scheme stages -> annotated-source hex0 -> stage0/M2, amd64 Linux.
# Host shell/file utilities orchestrate only; no imported seed is executed.
set -euo pipefail
if (( $# != 3 )); then
  echo "usage: $0 SEED PINNED_SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
seed=$(realpath "$1")
cache=$(realpath "$2")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$3"
out=$(realpath "$3")
mkdir "$out/recipe" "$out/bin"
cp -RL "$root/bootstrap" "$root/tests" "$out/recipe/"
b=$out/recipe/bootstrap
t=$out/recipe/tests
cp "$seed" "$out/qfitzah"
chmod +x "$out/qfitzah"
seed=$out/qfitzah
sha256sum "$seed" > "$out/seed.sha256"
bash "$t/bootstrap-artifacts.sh" "$seed" "$out/stages" "$out/recipe"
bash "$b/build-hex0.sh" "$seed" "$out/stages/rscB.elf" "$out/hex0"
bash "$t/hex0.sh" "$out/hex0/hex0"
bash "$b/blynn/export-stage0.sh" "$cache" "$out/stage0"
work=$out/stage0
# Explicit source assembly replaces both the imported hex0 and kaem seeds.
"$out/hex0/hex0" "$work/AMD64/hex0_AMD64.hex0" "$work/AMD64/artifact/hex0"
chmod 700 "$work/AMD64/artifact/hex0"
(
  cd "$work"
  ./AMD64/artifact/hex0 AMD64/hex0_AMD64.hex0 AMD64/artifact/hex0-again
  cmp AMD64/artifact/hex0 AMD64/artifact/hex0-again
  ./AMD64/artifact/hex0 AMD64/kaem-minimal.hex0 AMD64/artifact/kaem-0
  ./AMD64/artifact/kaem-0 AMD64/mescc-tools-mini-kaem.kaem
  # The same environment set by upstream AMD64/kaem.run, stopping before the
  # optional file utilities (which are outside our compiler dependency path).
  env ARCH=amd64 ARCH_DIR=AMD64 M2LIBC=../M2libc TOOLS=../AMD64/bin \
    BLOOD_FLAG=--64 BASE_ADDRESS=0x00600000 ENDIAN_FLAG=--little-endian \
    BINDIR=../AMD64/bin BUILDDIR=../AMD64/artifact TMPDIR=../AMD64/artifact \
    OPERATING_SYSTEM=Linux \
    ./AMD64/bin/kaem --verbose --strict --file AMD64/mescc-tools-full-kaem.kaem
  for tool in M2-Mesoplanet M2-Planet blood-elf M1 hex2 kaem; do
    grep -F "  AMD64/bin/$tool" amd64.answers | grep -E "/$tool$" > "$out/tool.answer"
    sha256sum -c "$out/tool.answer"
    cp "AMD64/bin/$tool" "$out/bin/$tool"
    chmod 555 "$out/bin/$tool"
  done
)
sha256sum "$out/bin/"* > "$out/tools.sha256"
printf 'ok - qfitzah-rooted stage0 tools; all six upstream answer hashes match\n'
