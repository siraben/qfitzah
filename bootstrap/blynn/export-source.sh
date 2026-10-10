#!/usr/bin/env bash
# Export one pinned commit, ignoring untracked files and mutable checkout state.
set -euo pipefail
if (( $# != 3 )); then
  echo "usage: $0 SOURCE_CACHE NAME NEW_DIRECTORY" >&2; exit 2
fi
cache=$(realpath "$1")
name=$2
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export GIT_NO_REPLACE_OBJECTS=1
while IFS=$'\t' read -r entry url revision tree; do
  if [[ $entry == "$name" ]]; then
    actual=$(git -C "$cache/$name" rev-parse "$revision^{tree}")
    [[ $actual == "$tree" ]] || { echo "source tree mismatch: $name" >&2; exit 1; }
    mkdir -- "$3"
    git -C "$cache/$name" archive --format=tar "$revision" | tar -xf - -C "$3"
    exit 0
  fi
done < "$b/sources.tsv"
echo "unknown pinned source: $name" >&2
exit 1
