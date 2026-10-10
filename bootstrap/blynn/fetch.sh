#!/usr/bin/env bash
# Fetch pinned Git objects only. Never execute a fetched binary or check out a
# mutable worktree. The bootstrap-seeds entry is an optional oracle, not input.
set -euo pipefail
if (( $# != 1 )); then echo "usage: $0 SOURCE_CACHE" >&2; exit 2; fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$1"
cache=$(realpath "$1")
export GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0
verify_source() {
  local name=$1 url=$2 commit=$3 tree=$4 repo=$cache/$1 actual
  if [[ ! -d $repo/.git ]]; then
    mkdir -p "$repo"
    git -C "$repo" init -q
  fi
  if ! git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$repo" fetch --no-tags --depth=1 "$url" "$commit"
  fi
  actual=$(git -C "$repo" rev-parse "$commit^{tree}")
  [[ $actual == "$tree" ]] || { echo "tree mismatch: $name" >&2; return 1; }
  printf '%s\t%s\t%s\n' "$name" "$commit" "$actual"
}
while IFS=$'\t' read -r name url commit tree; do
  case $name in ''|'#'*|stage0-posix/bootstrap-seeds) continue;; esac
  verify_source "$name" "$url" "$commit" "$tree"
done < "$here/sources.tsv"
