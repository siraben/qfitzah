#!/usr/bin/env bash
# Source-only assembly driver. Writes ELF to stdout; discard it on failure.
# The optional file supplies source macro overrides (e.g. a small GC heap).
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 SEED {scheme0|sc1|rsc} SOURCE [OVERRIDES]" >&2
  exit 2
fi
seed=$1
stage=$2
input=$3
b=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
sources=("$b/qfasm.qf1" "$b/runtime-support.qf1")
runtime=
case $stage in
  scheme0) ;;
  sc1) runtime=$b/sc1-runtime.qf1 ;;
  rsc)
    sources+=("$b/gc.qf1" "$b/io.qf1" "$b/control.qf1" "$b/lookup.qf1")
    runtime=$b/rsc-runtime.qf1
    ;;
  *) echo "unsupported assembly stage: $stage" >&2; exit 2 ;;
esac
if [[ $# == 4 ]]; then sources+=("$4"); fi
if [[ -n "$runtime" ]]; then sources+=("$runtime"); fi
# Large flat programs also consume the rewrite engine's recursive traversal
# stack. The 117k-line Mes host exceeds Linux's usual 8 MiB soft limit.
# Change only this assembly process; generated programs retain their own limits.
ulimit -s "${QFITZAH_ASSEMBLY_STACK_KIB:-65536}"
cat "${sources[@]}" "$input" | "$seed"
