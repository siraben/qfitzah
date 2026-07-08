#!/bin/sh
# gen-boot-cuts.sh — generate truncated boot-5 "cut" files (FD §5.5).
#
# Each cut is boot-5.scm truncated after loading a prefix of the module chain,
# then a marker print + (exit 42).  Running mes (reference or qmes) with
# MES_BOOT=<cut> under MES_PREFIX=build/mesroot loads only that prefix; the
# gate compares byte-exact stdout/stderr + exit status between hosts.
#
# The cut files are placed under the merged root at
#   build/mesroot/mes/module/mes/<cut>.scm
# so that open_boot finds them via MES_PREFIX and sets %datadir correctly
# (%datadir = MES_PREFIX/mes, %moduledir = %datadir/module/) — the type-0 and
# module.mes includes resolve relative to that.  Copies are also kept in
# build/boot-cuts/ for the sha256 manifest.
#
# B0 = boot prelude (boot-00..03 head, no type-0)
# B1 = + type-0.mes
# B2 = + module.mes
#
# Usage: tools/gen-boot-cuts.sh   (run make-mesroot.sh first)
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
boot5="$repo_root/third_party/mes/mes/module/mes/boot-5.scm"
cuts="$repo_root/build/boot-cuts"
moddir="$repo_root/build/mesroot/mes/module/mes"

[ -d "$moddir" ] || { echo "run tools/make-mesroot.sh first" >&2; exit 1; }
rm -rf "$cuts"; mkdir -p "$cuts"

# find the 1-based line numbers of the two include points.
type0_line=$(grep -n 'type-0\.mes' "$boot5" | head -1 | cut -d: -f1)
module_line=$(grep -n 'mes/module\.mes' "$boot5" | head -1 | cut -d: -f1)

emit() { # emit NAME LAST_LINE
  name=$1; last=$2
  f="$cuts/$name.scm"
  head -n "$last" "$boot5" > "$f"
  {
    printf '\n;; boot-cut gate marker\n'
    printf '(display "GATE-%s-OK")\n' "$name"
    printf '(display "\\n")\n'
    printf '(exit 42)\n'
  } >> "$f"
  ln -sf "$f" "$moddir/$name.scm"
  echo "[gen-boot-cuts] $name -> cut after line $last" >&2
}

# B0: everything up to (but not including) the type-0 include.
emit B0 $((type0_line - 1))
# B1: through the type-0 include, up to (but not including) module.mes include.
emit B1 $((module_line - 1))
# B2: through the module.mes include.
emit B2 "$module_line"

echo "[gen-boot-cuts] wrote $cuts and linked into $moddir" >&2
