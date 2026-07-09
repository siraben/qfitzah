# qmes vs mes-m2: the libtcc.c offsetof divergence — diagnosis

Status: root cause **confirmed by A/B instrumentation and a scratch fix trial**
(trial reverted; fix left to the implementing agent). 2026-07-08, branch
`mes-bootstrap`.

## Failure statement

Of the 10 TinyCC units compiled with MesCC (`mescc -S -m 32 --arch=x86`),
only `libtcc.c` differs between the reference interpreter `bin/mes-m2` and
`qmes.elf`. The divergence is in static data emitted for `FlagDef`-style
tables whose `offset` member is initialized with
`offsetof(struct TCCState, f)` = `((size_t)&((struct TCCState *)0)->f)`.

Independently reproduced bytes (12-line repro, `{offsetof(...)=0x50, 0, "unsupported"}`):

| host | bytes emitted for the element's `offset` member |
|---|---|
| `bin/mes-m2` (reference) | `'50' '00' '00' '00' '50' '00' '00' '00'` — low 32-bit word **repeated** |
| `qmes.elf` (wrong vs ref) | `'50' '00' '00' '00' '00' '00' '00' '00'` — mathematically correct zero high word |

Same pattern at the real site: `build/tcc/ref/libtcc.s:8017` (options_W /
options_f tables) shows `'50' ... '50' ...`, `'4c' ... '4c' ...`,
`'54' ... '54' ...`; the prior qmes sweep (`build/tcc/verify/libtcc.s`) zeroes
every second word. Elements with literal offset 0 (`{0,0,"all"}`) agree on
both hosts because both encodings of 0 are all-zero.

## The MesCC code path (why 8 bytes are emitted at all)

1. `init->data`, offsetof clause — `third_party/mes/module/mescc/compile.scm:2583`
   (and the `abs-declr` twin at `:2588`):

   ```scheme
   ((ref-to (i-sel (ident ,field) (cast (type-name (decl-spec-list ,struct) (abs-ptr-declr (pointer))) (p-expr (fixed ,base)))))
    (let* ((type (ast->type struct info))          ; <-- rebinds TYPE to the STRUCT type
           (offset (field-offset info type field))
           (base (cstring->int base)))
      (int->bv type (+ base offset) info)))        ; <-- emits with sizeof(struct)!
   ```

   MesCC (upstream bug, but deterministic and part of the reference output)
   passes the *struct* type, not the field's declared type, to `int->bv`.

2. `int->bv` — `compile.scm:2604`: `(->size type info)` = sizeof(struct
   TCCState) = 88 → the `case` falls to `(else (int->bv64 o))`. So the
   offsetof constant is emitted as **one 64-bit little-endian integer**
   (that's the "two words"), not as a (value, addend) reloc pair.

3. `int->bv64` — `third_party/mes/module/mescc/as.scm:34`:

   ```scheme
   (list (modulo value #x100)
         (modulo (ash value -8) #x100)
         ...
         (modulo (ash value -32) #x100)   ; byte 4  <-- the divergent byte(s)
         (modulo (ash value -40) #x100)
         (modulo (ash value -48) #x100)
         (modulo (ash value -56) #x100))
   ```

   Bytes 4–7 shift a 32-bit-cell number right by 32/40/48/56.

## Root cause (confirmed)

**`ash` with |count| ≥ 32 behaves differently on the two hosts.**

`bin/mes-m2`'s `ash` (`third_party/mes/src/math.c:293`) is
`cn >> -ccount` / `cn << ccount` on a 32-bit `long`, compiled by M2-Planet to
a single x86 `sar/shl %cl` — the CPU **masks the shift count to 5 bits**
(count mod 32). qmes's `b-ash` (`bootstrap/qmes.scm:2143`) forwards the raw
count to the runtime primitives `w32-shl` / `w32-sar`
(`bootstrap/gen-rsc-runtime.scm:78`, `w32-shift`), which loop a 1-bit shift
`count` times — counts ≥ 32 shift everything out (0, or −1 for `sar` of a
negative).

Direct A/B (script under both hosts, exact env):

| expr | mes-m2 | qmes (before fix) | qmes (masked, trial) |
|---|---|---|---|
| `(ash 80 -32)` | **80** | 0 | 80 |
| `(ash 80 -33)` | **40** | 0 | 40 |
| `(ash 80 -64)` | **80** | 0 | 80 |
| `(ash 80 32)`  | **80** | 0 | 80 |
| `(ash 80 33)`  | **160**| 0 | 160 |
| `(ash 1 100)`  | **16** | 0 | 16 |
| `(ash -80 -32)`| **-80**| -1 | -80 |
| `(ash 80 -31)` | 0 | 0 | 0 |

So in `int->bv64`, mes-m2 computes byte4 = `(v >> (32&31)) & 0xff = v & 0xff`,
byte5 = `v>>8`, byte6 = `v>>16`, byte7 = `v>>24` — i.e. it **repeats the low
word** — while qmes computes the true high word (0). Exactly the observed
byte patterns.

**End-to-end proof:** a scratch edit masking the shift magnitude
`(remainder c 32)` / `(remainder (- 0 c) 32)` in `b-ash`, rebuilt with
`make qmes`, made (a) all `ash` probes above match mes-m2 and (b) the 12-line
repro compile **byte-identical** (`cmp` clean). (Edit reverted; see "Fix
direction".)

## Ranked hypotheses

1. **[CONFIRMED] shift-count masking in `ash`.** MesCC calls
   `(ash value -32)` from `int->bv64` (as.scm:34) via the offsetof clause
   (compile.scm:2583→2604); qmes's `b-ash` (`bootstrap/qmes.scm:2143-2147`)
   returns 0 where mes-m2 returns `value`, because `w32-shl`/`w32-sar`
   (gen-rsc-runtime.scm:78) implement true shifts (loop-by-1) while mes-m2's
   C `>>`/`<<` on x86-32 masks the count mod 32.
   *Test:* `(ash 80 -32)` under both hosts → 80 vs 0. Done; matches.
   *Proof:* scratch-masked qmes reproduces mes-m2 byte-for-byte on the repro.

2. **[RULED OUT] wrong struct size / field offset in qmes** (e.g. a
   `field-offset` / `->size` / assq path returning 0). Would have corrupted
   the *first* word too; both hosts emit the identical low word (`'50'`,
   `'4c'`, `'54'`) and identical sizes everywhere else — 9/10 units already
   byte-identical. *Test:* first-word bytes agree in every divergent record.

3. **[RULED OUT] `modulo` divergence in `int->bv*`.** `(modulo x #x100)` is
   exercised for bytes 0–3 of every emitted integer in all 10 units and
   agrees; qmes's `b-modulo` already emulates the C algorithm.
   *Test:* bytes 0–3 and all `int->bv32`/`bv16` output identical across hosts.

## Smallest triggering C construct

4 lines (`struct` size must be > 4 so `int->bv` picks the 64-bit case, and
the field offset must be nonzero):

```c
typedef unsigned int size_t;
struct S8 { int a; int b; };
static size_t o = ((size_t)&((struct S8 *)0)->b);
int main() { return o; }
```

A/B results: struct size 8 → **diverges** (8 bytes, `04...04...` vs
`04...00...`); struct size 12 → diverges; struct size 4 → identical
(`int->bv32`, no ≥32 shift); `static long long x = 5;` → identical (plain
fixed initializers don't take the struct-typed `int->bv` path). It does NOT
need `offsetof`/tcc specifics — any static initializer matching the
`ref-to (i-sel … (cast … (fixed …)))` clause with sizeof(struct) ∉ {1,2,4}
and offset ≠ 0 triggers it.

## Fix direction (single locus)

`bootstrap/qmes.scm:2143` — mask the shift magnitude mod 32 in `b-ash`,
mirroring mes-m2's x86-32 hardware semantics (verified in the scratch trial):

```scheme
(define (b-ash a b)
  (let ((n (num-value a)) (c (w32->fixnum (num-value b))))
    (if (>= c 0)
        (make-number-w (w32-shl n (remainder c 32)))
        (make-number-w (w32-sar n (remainder (- 0 c) 32))))))
```

Do **not** change the `w32-shl`/`w32-sar` runtime primitives themselves —
they are used by asm.scm, the runtime generators and `qmes-w64.scm` with
in-range counts and callers may rely on true-shift semantics; `b-ash` is the
seam that emulates mes-m2's C `ash` (same pattern as the existing
`b-modulo`/`b-div` C-quirk emulations, incl. the documented M2-Planet
`divide` miscompile).

**Companion fix for S8 (x86_64 fixpoint):** `bootstrap/qmes-w64.scm:216` has
the same latent bug with modulus 64 — verified `bin/mes-m2-64` gives
`(ash 80 -64)` = 80 and `(ash 80 -32)` = 0, so the w64 `b-ash` should mask
`(remainder … 64)`.

Edge note: `c` = most-negative fixnum makes `(- 0 c)` overflow in both
implementations identically (mes-m2's C negation overflows the same way);
not reachable from MesCC.

## Repro commands

```sh
make qmes
# compile under HOST ∈ {bin/mes-m2, qmes.elf}; keep -o identical (it is embedded as a label)
env -i MES_PREFIX=$PWD/build/mesroot LANG= MES_DEBUG=0 %version=0.27.1 \
  MES_ARENA=20000000 MES_STACK=10000000 \
  GUILE_LOAD_PATH=$PWD/build/mesroot/mes/module srcdest=$PWD/third_party/mes/ \
  <HOST> --no-auto-compile -e main third_party/mes/module/mescc.scm -- \
  -S -m 32 --arch=x86 -I third_party/mes/include -o /tmp/o.s t-s8.c
cmp <mes-m2 out> <qmes out>    # divergence: 8-byte record, byte 5 onward
```

Full-unit check: compile `third_party/tinycc/libtcc.c` with
`-o build/tcc/canon/libtcc.s` (plus `-I build/tcc/include -I third_party/tinycc
-I third_party/mes/lib -I third_party/mes/include`) and `cmp` against
`build/tcc/ref/libtcc.s`.
