#!/usr/bin/env bash
# Fetch source archives only. Never runs upstream configure/build scripts.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "usage: $0 CACHE_DIRECTORY" >&2
  exit 2
fi
manifest=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/sources.tsv
mkdir -p -- "$1"
cache=$(cd -- "$1" && pwd)
part=
trap '[[ -z "$part" ]] || rm -f -- "$part"' EXIT
verify() {
  printf '%s  %s\n' "$2" "$1" | sha256sum --check --status
}
while read -r name hash url; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  target=$cache/$name
  if [[ -f "$target" ]]; then
    verify "$target" "$hash" || { echo "hash mismatch: $target" >&2; exit 1; }
  else
    part=$(mktemp "$cache/.download.XXXXXXXX")
    curl --fail --location --retry 2 --output "$part" "$url"
    verify "$part" "$hash" || { echo "hash mismatch: $url" >&2; exit 1; }
    mv -- "$part" "$target"
    part=
  fi
  printf '%s\n' "$target"
done < "$manifest"
