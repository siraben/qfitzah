#!/usr/bin/env bash
# Export one pinned commit, ignoring untracked files and mutable checkout state.
set -euo pipefail
if (( $# != 3 )); then
  echo "usage: $0 SOURCE_CACHE NAME NEW_DIRECTORY" >&2; exit 2
fi
cache=$(realpath "$1")
name=$2
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$b/source-lib.sh"
while IFS=$'\t' read -r entry url revision tree; do
  if [[ $entry == "$name" ]]; then
    [[ ! -e $3 && ! -L $3 ]] || { echo "output already exists: $3" >&2; exit 1; }
    export_pinned_source "$cache/$name" "$revision" "$tree" "$3"
    exit 0
  fi
done < "$b/sources.tsv"
echo "unknown pinned source: $name" >&2
exit 1
