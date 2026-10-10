#!/usr/bin/env bash
# Compile selected GNU Mes libc sources to M1, including its C crt1.
set -euo pipefail
if [[ $# != 5 ]]; then
  echo "usage: $0 {mini|tcc} MES_HOST MES_SOURCE GENERATED_NYACC NEW_DIRECTORY" >&2; exit 2
fi
mode=$1
host=$(realpath "$2")
mes=$(realpath "$3")
nyacc=$(realpath "$4")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "$mode" in
  mini) name=libc-mini; manifests=(mini.sources);;
  tcc) name=libc+tcc; manifests=(mini.sources tcc-extra.sources);;
  *) echo "unknown libc profile: $mode" >&2; exit 2;;
esac
mkdir -- "$5"
out=$(realpath "$5")
bash "$b/prepare-mes-libc.sh" "$mes" "$out/source" > /dev/null
# One translation unit avoids repeated tentative globals across libraries.
# Manifests contain unique source paths; no .o/.a or generated assembly is read.
for manifest in "${manifests[@]}"; do
  while IFS= read -r file; do
    case "$file" in ''|'#'*) continue;; esac
    test -f "$out/source/$file"
    cat "$out/source/$file"
    printf '\n'
  done < "$b/mes-libc/$manifest"
done > "$out/$name.c"
bash "$b/mescc.sh" "$host" "$out/source" "$nyacc" \
  -S --arch x86 -m32 -DHAVE_CONFIG_H=1 \
  -I "$out/source/include" -I "$out/source/include/linux/x86" \
  -o "$out/$name.M1" "$out/$name.c"
test -s "$out/$name.M1"
if [[ $mode == mini ]]; then
  # The upstream mini archive leaves write to full libc; supply a small,
  # source-compiled bufferless adapter for the independent mini milestone.
  bash "$b/mescc.sh" "$host" "$out/source" "$nyacc" \
    -S --arch x86 -m32 -DHAVE_CONFIG_H=1 -I "$out/source/include" \
    -o "$out/mini-write.M1" "$b/mes-libc/mini-write.c"
  cat "$out/mini-write.M1" >> "$out/$name.M1"
fi
printf '%s\n' "$out/$name.M1"
