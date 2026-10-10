#!/usr/bin/env bash
set -euo pipefail
if (( $# != 1 && $# != 3 )); then
  echo "usage: $0 SOURCE_COMPILER [SOURCE_BUILT_VM SINGULARITY_SOURCE]" >&2; exit 2
fi
compiler=$(realpath "$1")
if (( $# == 3 )); then
  vm=$(realpath "$2")
  source=$(realpath "$3")
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/qfitzah-singularity-test.XXXXXX")
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "singularity artifacts: $work" >&2; fi' EXIT
printf 'ident x = x; constant x y = x; main = ident;' > "$work/input"
printf 'I;``S`KKI;@ ;' > "$work/expected"
"$compiler" < "$work/input" > "$work/actual"
cmp "$work/expected" "$work/actual"
for bad in '' 'main = absent;' 'main = @' 'main = #;' 'main x x;' \
  'main=@I;main=@K;' 'main=next;next=@I;' 'main=main;'; do
  status=0
  printf '%s' "$bad" | "$compiler" > "$work/bad.out" 2> "$work/bad.err" || status=$?
  test "$status" = 1
  test ! -s "$work/bad.out"
done
# The last of 224 definitions can refer to byte-index 222; 225 is rejected.
letters=({a..z})
: > "$work/limit"
: > "$work/expected"
previous=
for ((i=0; i<224; ++i)); do
  name=${letters[i/26]}${letters[i%26]}
  if (( i < 223 )); then
    printf '%s=@I;' "$name" >> "$work/limit"
    printf 'I;' >> "$work/expected"
  else
    printf '%s=%s;' "$name" "$previous" >> "$work/limit"
    printf '@\376;' >> "$work/expected"
  fi
  previous=$name
done
"$compiler" < "$work/limit" > "$work/actual"
cmp "$work/expected" "$work/actual"
printf 'zz=@I;' >> "$work/limit"
status=0
"$compiler" < "$work/limit" > "$work/bad.out" 2> "$work/bad.err" || status=$?
test "$status" = 1
test ! -s "$work/bad.out"
if (( $# == 1 )); then
  echo 'ok - singularity parsing, SKI goldens and global-reference guards'
  exit 0
fi
# Execute independent small programs, not just a compiler fixpoint.
printf 'qfitzah to Blynn\n' > "$work/text"
for program in 'main s = s;' 'main s = (\s -> s) s;'; do
  printf '%s' "$program" | "$compiler" > "$work/program.ion"
  "$vm" --raw "$work/program.ion" -pb probe -lf "$work/text" -o "$work/echo"
  cmp "$work/text" "$work/echo"
done
printf 'main s = @: #X s;' | "$compiler" > "$work/program.ion"
"$vm" --raw "$work/program.ion" -pb prefix -lf "$work/text" -o "$work/prefix"
printf 'Xqfitzah to Blynn\n' > "$work/expected"
cmp "$work/expected" "$work/prefix"
"$compiler" < "$source" > "$work/bootstrap.ion"
"$vm" --raw "$work/bootstrap.ion" -pb singularity -lf "$source" -o "$work/self.ion"
cmp "$work/bootstrap.ion" "$work/self.ion"
echo 'ok - singularity parsing, bracket abstraction, VM execution and source self-compilation'
