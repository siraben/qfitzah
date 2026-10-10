#!/usr/bin/env bash
# Check source staging, artifact removal and manifests; never compile/evaluate
# an archive's generated parser artifacts. This is not a compiler-build test.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "usage: $0 VERIFIED_MES_SOURCE VERIFIED_NYACC_SOURCE VERIFIED_TCC_SOURCE" >&2; exit 2
fi
mes=$(realpath "$1")
nyacc=$(realpath "$2")
tcc=$(realpath "$3")
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
b=$root/bootstrap
work=$(mktemp -d /tmp/qfitzah-preparation-test.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "preparation artifacts: $work" >&2; fi' EXIT
sources=("$nyacc/module/nyacc/lang/c99/cpp.scm" "$tcc/tcctools.c" "$mes/include/mes/lib-mini.h")
for grammar in cpp c99 c99x c99cx; do
  for part in act tab; do
    sources+=("$nyacc/module/nyacc/lang/c99/mach.d/$grammar-$part.scm")
  done
done
sha256sum "${sources[@]}" > "$work/originals.sha256"
bash "$b/prepare-nyacc.sh" "$nyacc" "$work/nyacc" > /dev/null
for grammar in cpp c99 c99x c99cx; do
  for part in act tab; do
    test ! -e "$work/nyacc/module/nyacc/lang/c99/mach.d/$grammar-$part.scm"
  done
done
patch --batch --dry-run --reverse --fuzz=0 -d "$work/nyacc" -p1 \
  < "$b/upstream/patches/nyacc-mes-modules.patch"
bash "$b/prepare-mes-libc.sh" "$mes" "$work/mes" > /dev/null
for header in kernel-stat.h signal.h syscall.h; do
  cmp "$mes/include/linux/x86/$header" "$work/mes/include/arch/$header"
done
printf '#undef SYSTEM_LIBC\n#define MES_VERSION "0.27.1"\n' > "$work/config.h"
cmp "$work/config.h" "$work/mes/include/mes/config.h"
bash "$b/prepare-tcc.sh" "$tcc" "$work/tcc" > /dev/null
patch --batch --dry-run --reverse --fuzz=0 -d "$work/tcc" -p1 \
  < "$b/upstream/patches/tcc-ar-open.patch"
for profile in mescc tcc; do
  if [[ $profile == mescc ]]; then
    manifests=(mini.sources tcc-extra.sources); expected=158
  else
    manifests=(unified.sources); expected=258
  fi
  : > "$work/sources"
  for manifest in "${manifests[@]}"; do
    while IFS= read -r file; do
      case "$file" in ''|'#'*) continue;; esac
      test -f "$mes/$file"
      printf '%s\n' "$file" >> "$work/sources"
    done < "$b/mes-libc/$manifest"
  done
  test "$(wc -l < "$work/sources")" = "$expected"
  sort "$work/sources" | uniq -d > "$work/duplicates"
  test ! -s "$work/duplicates"
done
# Destination refusal must leave the completed preparation unchanged.
sha256sum "$work/tcc/tcctools.c" "$work/tcc/config.h" > "$work/prepared.sha256"
if bash "$b/prepare-tcc.sh" "$tcc" "$work/tcc" > "$work/rejected" 2>&1; then
  echo 'preparation unexpectedly reused a destination' >&2; exit 1
fi
sha256sum -c "$work/prepared.sha256"
sha256sum -c "$work/originals.sha256"
echo 'ok - source preparation, parser-artifact removal and libc manifests'
