# qmes → MesCC → tcc: COMPLETE

Source: janneke/tinycc `mes-0.27` @ 0bbd2af (submodule `third_party/tinycc`).
Reference: `bin/mes-m2` (M2-Planet Mes). Harness: `tools/build-tcc.sh`, `make tcc`.

**qmes — a full GNU Mes built from a 1.7 KiB seed with NO C and NO Python —
compiles TinyCC to a binary byte-identical to the M2-Planet reference, and that
tcc compiles+runs C and self-hosts to a byte-identical fixpoint.**

## T0 — reference tcc under mes-m2: DONE
All 10 tcc units compile under `bin/mes-m2`; reference `.s` hashes committed
(`tests/mescc-references/tcc/t0.sha256`). Links to `bin/tcc-mes.ref` (474310 B),
`tcc version 0.9.27 (i386 Linux)`, compiles+runs hello.c (exit 42).

## T1 — qmes compiles tcc: 10/10 byte-identical
`mescc -S -m 32 --arch=x86` over the 10 units (tccpp, tccgen, tccelf, tccrun,
i386-gen, i386-link, i386-asm, tccasm, libtcc, tcc) under `qmes.elf` vs
`bin/mes-m2` — **all 10 byte-identical**. Initially 9/10; the one divergence
(libtcc.c's `options_W`/`options_f` FlagDef `offsetof(TCCState,field)` static
initializers) was a real qmes bug: `b-ash` didn't mask the shift count mod 32,
so MesCC's offsetof-via-`ash 32` got zeroed instead of preserved (x86 masks
shift counts mod word size). Fixed in `bootstrap/qmes.scm` b-ash (+ companion
mod-64 fix in `qmes-w64.scm`); see `docs/qmes-tcc-offsetof-diagnosis.md`.

## T2 — qmes-path tcc: byte-identical linked binary
Linking the qmes 10 `.s` (crt1 + units + libc+tcc, mescc-tools) → `bin/tcc-
mes.qmes` (474310 B) is **byte-identical to `bin/tcc-mes.ref`** (sha256
6e3ddd53…). It runs: `tcc version 0.9.27`, compiles+runs hello.c (exit 42).

## T3 — tcc self-host fixpoint: DONE
The qmes-built tcc recompiles the tcc sources; the chain converges byte-exactly:
`tcc-boot5 == tcc-boot6` (256288 B). A genuine self-hosting TinyCC reached with
no C compiler in its ancestry.

## Chain
seed (1.7 KiB asm) → qfasm → scheme0 → sc1 → rsc → qmes (Mes) → MesCC →
**TinyCC** (byte-identical to the M2-Planet path, self-hosting), no C, no Python.
