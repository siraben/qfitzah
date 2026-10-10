#!/usr/bin/env bash
# Export through a private object-only view. The cache's config, replacement
# refs, worktree and info/attributes must not change a pinned source export.
export_pinned_source() (
  set -euo pipefail
  repo=$1 revision=$2 expected_tree=$3 destination=$4
  export GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  objects=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects)
  view=$(mktemp -d)
  trap 'rm -rf "$view"' EXIT
  git init --bare --template= -q "$view"
  printf '%s\n' "$objects" > "$view/objects/info/alternates"
  actual=$(git --git-dir="$view" rev-parse "$revision^{tree}")
  [[ $actual == "$expected_tree" ]] || {
    echo "source tree mismatch: $repo" >&2
    exit 1
  }
  mkdir -p -- "$destination"
  git --git-dir="$view" archive --format=tar "$revision" | tar -xf - -C "$destination"
)
