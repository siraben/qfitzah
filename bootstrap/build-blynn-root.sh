#!/usr/bin/env bash
# Enter the pinned Blynn ladder from singularity SOURCE, not bundled blobs.
set -euo pipefail
if (( $# != 4 )); then
  echo "usage: $0 QFITZAH_TOOLS SINGULARITY_COMPILER SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
tools=$(realpath "$1")
compiler=$(realpath "$2")
cache=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -- "$4"
out=$(realpath "$4")
mkdir "$out/bin" "$out/generated" "$out/share" "$out/tmp"
b=$root/bootstrap
t=$root/tests
sha256sum -c "$tools/tools.sha256"
bash "$b/blynn/export-source.sh" "$cache" blynn-bootstrap "$out/target"
bash "$b/blynn/export-source.sh" "$cache" oriansj-blynn-compiler "$out/source"
src=$out/source
while IFS= read -r patch; do
  [[ -z $patch ]] || (cd "$src" && patch --batch --fuzz=0 -p1 < "$out/target/patches/upstreams/$patch")
done < "$out/target/patches/upstreams/oriansj-blynn-compiler.series"
(cd "$src" && patch --batch --fuzz=0 -p1 < "$b/blynn/patches/vm-buffer-end.patch")
# Make accidental use of the precompiled starting programs impossible.
rm -rf "$src/blob"
rmdir "$src/M2libc"
ln -s "$tools/stage0/M2libc" "$src/M2libc"
export PATH="$tools/bin:$PATH" TMPDIR="$out/tmp"
export M2LIBC_PATH="$tools/stage0/M2libc"
gen=$out/generated
bin=$out/bin
compile_c() {
  "$tools/bin/M2-Mesoplanet" --operating-system Linux --architecture amd64 \
    -f "$1" -o "$2"
  chmod 555 "$2"
}
cd "$src"
compile_c vm.c "$bin/vm"
"$compiler" < singularity > "$gen/singularity.ion"
bash "$t/singularity.sh" "$compiler" "$bin/vm" "$src/singularity"
"$bin/vm" --raw "$gen/singularity.ion" -pb singularity -lf singularity -o "$gen/raw_p"
cmp "$gen/singularity.ion" "$gen/raw_p"
previous=$gen/raw_p
stages=(semantically stringy binary algebraically parity.hs fixity.hs typically.hs classy.hs barely.hs barely.hs)
letters=(q r s t u v w x y z)
for i in "${!stages[@]}"; do
  output=$gen/raw_${letters[$i]}
  echo "Blynn level: ${stages[$i]} -> $output"
  "$bin/vm" --raw "$previous" -pb "${stages[$i]}" -lf "${stages[$i]}" -o "$output"
  previous=$output
done
"$bin/vm" -l "$gen/raw_z" -lf barely.hs -o "$out/share/raw"
"$bin/vm" -l "$out/share/raw" -lf effectively.hs --redo -lf lonely.hs -o "$gen/lonely_raw.txt"
previous=$gen/lonely_raw.txt
for name in patty guardedly assembly mutually uniquely virtually; do
  foreign=()
  case $name in mutually|uniquely|virtually) foreign=(--foreign 2);; esac
  echo "Blynn runtime level: $name"
  "$bin/vm" -f "$name.hs" "${foreign[@]}" --raw "$previous" --rts_c run -o "$gen/${name}_raw.txt"
  previous=$gen/${name}_raw.txt
done
"$bin/vm" -f marginally.hs --foreign 2 --raw "$previous" --rts_c run -o "$gen/marginally.c"
compile_c "$gen/marginally.c" "$bin/marginally"
previous=marginally
for name in methodically crossly precisely; do
  echo "Blynn native level: $name"
  "$bin/$previous" "$name.hs" "$gen/$name.c"
  compile_c "$gen/$name.c" "$bin/$name"
  previous=$name
done
sha256sum "$bin/"* "$gen/singularity.ion" > "$out/root.sha256"
echo 'ok - qfitzah-rooted Blynn native ladder; no initial combinator blobs used'
