# qmes → MesCC → tcc: status

Source: janneke/tinycc `mes-0.27` @ 0bbd2af (submodule `third_party/tinycc`).
Reference: `bin/mes-m2` (M2-Planet Mes). Harness: `tools/build-tcc.sh`, `make tcc`.

## T0 — reference tcc under mes-m2: DONE
All 10 tcc units compile under `bin/mes-m2`; reference `.s` hashes committed
(`tests/mescc-references/tcc/t0.sha256`). (The reference *link* is a separate
harness fix — `link_tcc` must mirror the proven recipe `mescc -m 32 --arch=x86
-o tcc -L build/mescc-lib <10 .s> -l c+tcc`, no `-nostdlib`/`-l mescc`.)

## T1 — qmes compiles tcc: 9/10 byte-identical
`mescc -S -m 32 --arch=x86` over the 10 units under `qmes.elf` vs `bin/mes-m2`,
byte-compared:
- **9/10 BYTE-IDENTICAL**, including the biggest units: tccpp (853 KB), tccgen
  (829 KB), tccelf, i386-asm, i386-gen, i386-link, tccasm, tccrun, tcc.
- **1 divergence: `libtcc.s`** (both 174448 B, same size). Localized to the
  `options_W[]` / `options_f[]` `FlagDef` tables (libtcc.c:1603+):
  `{ offsetof(TCCState, warn_xxx), FLAGS, "name" }`. `offsetof` =
  `(size_t)&((TCCState*)0)->field`. In a static initializer qmes's MesCC emits
  the offsetof-derived word differently from mes-m2 (ref: `50 00 00 00 50 00 00
  00`, qmes: `50 00 00 00 00 00 00 00` — the value duplicated by the reference
  is zeroed by qmes). A MesCC constant-folding/emission divergence for
  address-of-member-of-null in a static initializer. Under Fable diagnosis.

## Remaining
Fix the libtcc offsetof divergence (→ T1 10/10), fix `link_tcc`, then T2 (link
the qmes tcc, cmp binary, hello exit 42) and T3 (tcc self-host fixpoint).
