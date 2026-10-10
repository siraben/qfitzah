#!/usr/bin/env bash
# Object-export boundary tests: file utilities only, no compiler invocation.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/qfitzah-blynn-sources-test.XXXXXX)
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "source boundary artifacts: $work" >&2; fi' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
mkdir -p "$work/scripts" "$work/cache/toy"
cp "$root/bootstrap/blynn/"{export-source,fetch}.sh "$work/scripts/"
git -C "$work/cache/toy" init -q
printf 'trusted source\n' > "$work/cache/toy/payload"
git -C "$work/cache/toy" add payload
git -C "$work/cache/toy" -c user.name=Test -c user.email=test@example.invalid commit -qm source
revision=$(git -C "$work/cache/toy" rev-parse HEAD)
tree=$(git -C "$work/cache/toy" rev-parse HEAD^{tree})
printf 'toy\tfile://%s/cache/toy\t%s\t%s\n' "$work" "$revision" "$tree" > "$work/scripts/sources.tsv"
printf 'trusted source\n' > "$work/expected"
printf 'mutable worktree\n' > "$work/cache/toy/payload"
printf 'untracked injected file\n' > "$work/cache/toy/injected"
bash "$work/scripts/export-source.sh" "$work/cache" toy "$work/export"
cmp "$work/expected" "$work/export/payload"
test ! -e "$work/export/injected"
# Replacement objects must not silently substitute a different source tree.
git -C "$work/cache/toy" add payload
git -C "$work/cache/toy" -c user.name=Test -c user.email=test@example.invalid commit -qm replacement
git -C "$work/cache/toy" replace "$revision" HEAD
bash "$work/scripts/export-source.sh" "$work/cache" toy "$work/replaced"
cmp "$work/expected" "$work/replaced/payload"
# Refuse an existing output without altering it.
if bash "$work/scripts/export-source.sh" "$work/cache" toy "$work/export" 2> "$work/error"; then exit 1; fi
cmp "$work/expected" "$work/export/payload"
cp "$work/scripts/sources.tsv" "$work/pin"
printf 'toy\tunused\t%s\t0000000000000000000000000000000000000000\n' "$revision" > "$work/scripts/sources.tsv"
if bash "$work/scripts/export-source.sh" "$work/cache" toy "$work/bad" 2> "$work/error"; then exit 1; fi
test ! -e "$work/bad"
cp "$work/pin" "$work/scripts/sources.tsv"
# Fetch only Git objects; do not check out files or fetch the unused seed oracle.
printf 'stage0-posix/bootstrap-seeds\tfile:///nonexistent-oracle\t%s\t%s\n' "$revision" "$tree" >> "$work/scripts/sources.tsv"
bash "$work/scripts/fetch.sh" "$work/fetched" > "$work/fetched.tsv"
test ! -e "$work/fetched/toy/payload"
test ! -e "$work/fetched/stage0-posix/bootstrap-seeds"
bash "$work/scripts/export-source.sh" "$work/fetched" toy "$work/fetched-export"
cmp "$work/expected" "$work/fetched-export/payload"
echo 'ok - pinned objects, dirty-worktree isolation, replacement-object rejection and source-only fetch'
