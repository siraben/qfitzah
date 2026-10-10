#!/usr/bin/env bash
# Export pinned Git objects, not mutable worktrees or imported executable seeds.
set -euo pipefail
if (( $# != 2 )); then
  echo "usage: $0 SOURCE_CACHE NEW_DIRECTORY" >&2; exit 2
fi
cache=$(realpath "$1")
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -- "$2"
out=$(realpath "$2")
source "$b/source-lib.sh"
while IFS=$'\t' read -r name url revision tree; do
  case $name in
    stage0-posix/bootstrap-seeds) continue ;;
    stage0-posix|stage0-posix/*) ;;
    *) continue ;;
  esac
  dest=$out
  if [[ $name != stage0-posix ]]; then dest=$out/${name#stage0-posix/}; fi
  export_pinned_source "$cache/$name" "$revision" "$tree" "$dest"
  printf '%s\t%s\t%s\n' "$name" "$revision" "$tree" >> "$out/source-commits.tsv"
done < "$b/sources.tsv"
# Root Gitlinks create empty directories. Never populate this one with seeds.
rmdir "$out/bootstrap-seeds"
test -f "$out/AMD64/hex0_AMD64.hex0"
test -f "$out/mescc-tools/hex2.c"
