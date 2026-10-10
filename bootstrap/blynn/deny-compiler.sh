#!/usr/bin/env bash
# Host compiler discovery is a recipe error, never a fallback.
printf 'forbidden host compiler/tool fallback: %s\n' "$0" >&2
exit 126
