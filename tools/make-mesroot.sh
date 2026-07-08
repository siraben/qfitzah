#!/bin/sh
# make-mesroot.sh — synthesize the merged Mes module root (FD §5.4).
#
# GNU Mes computes %datadir = $MES_PREFIX/mes and %moduledir = %datadir/module/
# (mes.c open_boot + boot-5.scm:139).  The *installed* layout overlays two
# source trees into that one directory:
#
#     $MES_PREFIX/mes/module/  =  third_party/mes/mes/module/*   (the core half:
#                                    mes/, srfi/, ice-9/, nyacc/, rnrs/, ...)
#                              ∪  third_party/mes/module/*       (the top half:
#                                    mes/getopt-long, mescc/, mescc.scm, ...)
#
# Without the overlay the reference dies in process-use-modules on
# (mes getopt-long).  With it, mes-m2 reaches (top-main).  This script builds
# that merged root as a tree of symlinks under build/mesroot — it NEVER
# modifies anything under third_party.
#
# Usage: tools/make-mesroot.sh   ->   build/mesroot   (MES_PREFIX for boot)
set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tp="$repo_root/third_party/mes"
nyacc="$repo_root/third_party/nyacc"
root="$repo_root/build/mesroot"
dest="$root/mes/module"          # == %moduledir under MES_PREFIX=build/mesroot

rm -rf "$root"
mkdir -p "$dest"

# overlay SRC into $dest: for every regular file under SRC, make a symlink at
# the mirrored path in $dest (creating parent dirs).  Later overlays win, but
# the two trees are disjoint except for guile.scm/mes-0.scm which are identical
# copies, so order is immaterial.
overlay() {
  src=$1
  ( cd "$src" && find . \( -type f -o -type l \) -print ) | while IFS= read -r rel; do
    rel=${rel#./}
    d=$(dirname "$rel")
    mkdir -p "$dest/$d"
    ln -sf "$src/$rel" "$dest/$rel"
  done
}

# nyacc (S5): the vendored nyacc submodule supplies the full C99 parser stack
# (nyacc/lang/c99/parser.scm, cpp.scm, version.scm, util.scm, ...) that MesCC's
# preprocess.scm imports.  Mes's own tree ships only two nyacc files
# (nyacc/compat18.scm and nyacc/lang/c99/pprint.scm — a Mes-customised pretty
# printer); those must WIN over the vendored copies, so overlay the vendored
# nyacc FIRST and let the two Mes trees below overwrite the two shared files.
# Vendored nyacc version: 2.02.5 (third_party/nyacc, pinned as a submodule).
overlay "$nyacc/module"

# Overlay the top half next, then the core half, so that on the files present
# in more than one tree (mes-0.scm, guile.scm, and the two nyacc files above)
# the Mes-native versions in mes/module/ win over the Guile-compat / vendored
# versions — the reference host is Mes, so it must load the Mes-native shims
# (the Guile ones reference major-version / effective-version which do not
# exist here).
overlay "$tp/module"
overlay "$tp/mes/module"

echo "[make-mesroot] wrote $root" >&2
echo "[make-mesroot] MES_PREFIX=$root  %moduledir=$dest" >&2
