# qmes x86_64 design: the 64-bit number substrate and the F1/F2/F3-64 fixpoint

Status: DESIGN (Fable, 2026-07-08). Implements roadmap Track C (S7/S8,
`docs/mes-fixpoint-roadmap.md`) and supersedes the sketch in
`docs/qmes-full-design.md` §7.2 (which proposed 4-word cells — rejected here,
see §2.2). The i386 fixpoint is CLOSED (F1 20/20, F2 byte-identical, F3
clean); nothing in this design may perturb that artifact except through the
re-run gates named below.

Every claim below is grounded in a file:line or in one of two experiments run
on this tree on 2026-07-08 (§1.1, §1.5).

---

## 0. Decisions at a glance

| Question | Decision |
|---|---|
| Q3 scope: does MesCC-x86_64 do 64-bit host *arithmetic*? | **Yes — real arithmetic, not read/print-only** (§1). But it is fully funneled through Mes's ~13 `math.c` builtins + reader + printer + number-equality. No bignums: semantics = C `long` wraparound mod 2^64. |
| Representation | TNUMBER cell = `[TNUMBER | hi | lo]` — the **existing 3-word cell**, high word in the (currently zero) car slot. No stride change, no GC change, no arena resize (§2.2). |
| w64 ops: runtime prims or Scheme? | **Pure Scheme over the existing w32 prims** (`bootstrap/qmes-w64.scm`). `generate_rsc_runtime.py` and the committed runtimes are untouched. Two named escape-hatch prims if the F1-64 sweep is intolerably slow (§2.5). |
| qmes-64: variant or mode? | **Build-time variant of the same source**: `cat rsc-prelude qmes.scm qmes-w64.scm qmes-main.scm`, using rsc's last-define-wins override semantics. The i386 build (`cat` without the w64 file) stays byte-identical (§3). |
| x86_64 reference | `bin/mes-m2-64` via the kaem.x86_64 parameters (M2-Planet `--architecture amd64`, blood-elf `--64`, M1/hex2 amd64) — nixpkgs tool support **verified** (§4.1). The i386 `bin/mes-m2` **cannot** cross-host `--arch=x86_64`: proven, exit 139 `divide-by-zero: (-1)` (§1.1). |
| Gate | `make fixpoint-64` = F1-64 (20 units, qmes-64 vs mes-m2-64) + F2-64 (amd64 link, cmp) + F3-64 (the ELF64 mes runs natively, re-sweep) (§4.3). |
| Biggest risk | w64 semantic corners (div/mod sign folding, sar, shift-count masking) silently diverging from M2-Planet-amd64-compiled `math.c` — killed early by a differential torture-matrix gate that runs *before* any sweep (§5, §6). |

---

## 1. Q3 — what 64-bit host arithmetic MesCC-x86_64 actually performs

### 1.1 Two experiments (reproduced on this tree)

**The i386 reference cannot host the x86_64 backend.** Compiling
`int main() { return -1; }` with
`bin/mes-m2 … mescc.scm -- -S -m 64 --arch=x86_64 …` dies:

```
unhandled exception: divide-by-zero: (-1)     [exit 139]
```

Mechanism: `return -1` → `x86_64:value->r` (x86_64/as.scm:82-88) takes the
`#:immediate8` branch for any negative value → `hex2:immediate8`
(M1.scm:92-98) evaluates `(modulo o #x100000000)`. mes-m2's 32-bit reader
wraps the literal `#x100000000` to 0; `(modulo -1 0)` faults. This proves
both halves of Q3/Q4 at once: the host **executes** 64-bit arithmetic on this
path (it is not just string formatting), and a genuine 64-bit reference is
mandatory.

**Ground truth of the hot path** (Guile 3.0.11 hosting the same mescc on the
same file):

```
:main
	push___%rbp
	mov____%rsp,%rbp
	sub____$i32,%rsp %0x20a8
	mov____$i64,%rax %0xffffffff %0x-1
	...
```

So *every* negative C literal (`-1` is ubiquitous in src/*.c) produces an
`#:immediate8`, whose low word `0xffffffff = 4294967295` exceeds both the
signed-32-bit range and the rsc 30-bit fixnum. The high word of a negative
immediate is emitted as the literal string `"-1"` (M1.scm:94), giving the
quirky-but-canonical `%0x-1` — textual parity only requires reproducing the
string, which falls out of correct 64-bit `modulo` + `number->string`.

### 1.2 The full host-side op census (file:line)

Values reaching the number paths come from `cstring->int`
(compile.scm:1613-1624, `string->number` radix 16/8/2/10) and constant
folding (`try-expr->number`, compile.scm:1630-1669: `+ - * quotient logand
logior lognot ash`). Corpus check: **no literal ≥ 2^31 is compiled** for the
mes build — grep of src/ lib/ include/ finds 8+-hex-digit / 10+-decimal-digit
literals only inside `#if 0` (lib/mes/div.c:109-112) and in `*-gcc`
`__asm__` strings; the largest live literal is `1000000000` (src/posix.c).
So parsing stays under 2^31; **the ≥ 32-bit values are manufactured by MesCC
itself**, in exactly these places:

| Site | Operation | 64-bit range hit |
|---|---|---|
| M1.scm:93-98 `hex2:immediate8` | `modulo o #x100000000`, `quotient o #x100000000`, `< o 0` | low word up to 2^32−1; the literal `#x100000000` itself must be *read* |
| as.scm:34-42 `int->bv64` | `ash value -8 … -56`, `modulo _ #x100` | arithmetic shift of negative 64-bit values (e.g. a `long x = -1;` global initializer, via compile.scm:2610 `int->bv` reg-size 8) |
| as.scm:44-48 `int->bv32` | same, ≤ −24 | negative initializers (already exercised on i386) |
| as.scm:57-60 `dec->hex` | `number->string n 16` | n up to 2^32−1 (the immediate8 low word) — this is interpreted Scheme: scm.mes:326-335 loops `quotient`/`remainder` by the radix |
| x86_64/as.scm:82-88, 493-501, 526-535, 614-623, 646-652 (`value->r`, `r+value`, `r-cmp-value`, `r-long-mem-add`, `r-and`) | `(>= v 0)`, `(< v #x80000000)`, `(abs v)` guards | signed compares against 2^31 where v may be any folded constant; `-129 ≤ v < -128` etc. also select `#:immediate8` |
| compile.scm:1636-1659 folding | `- + * quotient logand logior lognot ash` | inputs < 2^31 in corpus, but results feed the guards/printers above |
| scm.mes:381,400-401 | `quotient = /`, `remainder` derived as `x − (x/y)·y` | so **Mes's `/` builtin (`divide`, math.c:143) is the single division primitive** for all of the above |

Dead code worth knowing: the "AMD" variants of `x86_64:function-preamble`,
`ret`, `r->arg`, `label->arg` (x86_64/as.scm:52-63, 91-95, 121-130) are
shadowed by the later "traditional" redefinitions (65-68, 97-101, 132-139),
so the `#:address8`-via-`label->arg` path never fires; `int->bv64` is reached
only through 8-byte global initializers.

### 1.3 The scope finding

"Read/format-only" is **false**: the format path itself divides by 2^32 and
by 16, shifts by up to 56, and compares signed 64-bit values. But "full
64-bit" is **bounded and closed**: because MesCC is *interpreted Scheme*,
every host-side operation funnels through Mes's builtin surface. The complete
set qmes-64 must widen is:

- **math.c builtins** (qmes.scm:2066-2172, 2385): `+ - * / modulo ash
  logand logior logxor lognot = < >` (13; `quotient`/`remainder`/`abs`/`<=`
  />=` are derived Scheme, scm.mes:381-431 — they inherit correctness).
- **reader**: decimal `parse-number`/`parse-digits` (qmes.scm:1265-1277,
  `acc*10+d` must wrap mod 2^64) and `#x/#b/#o` `reader-read-radix`
  (qmes.scm:1409-1412, `acc<<shift + d` — this is what reads
  `#x100000000` from M1.scm source).
- **printer**: decimal display of a TNUMBER (qmes.scm:2002-2011) — used by
  `display` in scaffold gates and error paths.
- **number equality**: `eq?/eqv?/equal2?/assq/memq` value comparison sites
  (qmes.scm:442, 1928, 1983, plus the `b-is` loop) — must compare both words.
- **number copy**: qmes.scm:460 (`make-number-w (num-value e)`) and
  `core:car`/`core:cdr` raw wraps (qmes.scm:2093-2100).

Division corner: general 64÷64 with a large divisor essentially never occurs
in the corpus (divisors seen: 2, 8, 10, 16, 2^32), but `divide` must still be
*correct* for all inputs because the F3-64 gate re-hosts the sweep and the
scaffold ladder compares arbitrary scripts. Hash functions are **not**
width-sensitive: `hash_cstring` (hash.c:28-37) uses only the first two name
bytes — no overflow, no bucket-order divergence.

No bignum is ever needed: mes-m2-64's numbers are C `long`s compiled by
M2-Planet for amd64; all semantics are two's-complement mod 2^64 with x86
shift-count masking (§2.4).

---

## 2. The number substrate: representation and op set

### 2.1 Constraints from the rsc dialect

- rsc fixnums are 30-bit (value·4+1, generate_rsc_runtime.py:1236-1242);
  `w32->fixnum` truncates. Full words live only in w32 boxes.
- Existing w32 prim set (generate_rsc_runtime.py:78-89): `w32-from-fixnum
  w32->fixnum w32-add w32-sub w32-mul(low 32) w32-quot w32-rem w32-uquot
  w32-urem w32-and w32-or w32-xor w32-not w32-shl w32-shr w32-sar(fixnum
  count) w32-eq? w32-lt? w32-ult?` + `vec-raw-ref/set!`. There is **no**
  32×32→hi64 multiply and no 64÷32 divide prim.

### 2.2 TNUMBER = `[TNUMBER | hi | lo]` (3-word cell, hi in the car word)

Today a TNUMBER is `[TNUMBER | 0 | value]` (qmes.scm:135-144). qmes-64 puts
the high 32 bits in the car word. Why this beats FD §7.2's 4-word cells:

- **GC is provably untouched.** The collector classifies pointer fields by
  type lists (qmes.scm:1566-1580: `gc-car-ptr?` = {TMACRO TPAIR TREF
  TBINDING}, `gc-cdr-ptr-*` exclude TNUMBER); TNUMBER's car and cdr are both
  copied **raw** in gc-copy and gc-cellcpy. Storing hi in car requires zero
  GC edits.
- No stride change: `raw-ref/raw-set!` (qmes.scm:53-54) keep `3i+off`; no
  arena resize (cells stay 12 bytes); no reaudit of every `* 3` site.
- All index/fd/length consumers keep reading `num-value` (= lo) unchanged.

Divergence note: mes-m2-64's number cells have car = 0, so `core:car` of a
number returns the hi word under qmes-64 instead of 0. No boot-5, nyacc, or
mescc code calls `core:car` on numbers (it is used on structs/pairs); if a
scaffold rung ever trips on this, the fallback is one line in the override
(`b-core-car` special-cases TNUMBER → 0 to mimic the C layout). Do not
pre-pessimize.

Constructors/accessors (in the override file, §3):

```scheme
(define (make-number-2w hi lo) …)         ; new: writes car=hi, cdr=lo
(define (make-number-w w)                  ; OVERRIDE: sign-extend one word
  (make-number-2w (w32-sar w 31) w))
;; make-number-fx unchanged (delegates to make-number-w)
(define (num-hi i) (raw-ref i 1))          ; new
;; num-value (lo) and num-fixnum unchanged
```

The sign-extending `make-number-w` keeps every legacy single-word call site
(string-length, char->integer, struct indices, …) correct without touching
it.

### 2.3 In-flight w64 values

Inside the widened builtins a 64-bit value is threaded as **two separate w32
boxes** (`hi lo` argument pairs in loops, e.g.
`(plus-loop x acc-hi acc-lo)`); where a helper must return both (divmod), it
returns a fresh host pair `(cons hi lo)`. All of this is transient host heap,
reclaimed by the existing `host-heap-reset!` discipline (builtins run between
gc-check/reset sites) — no new persistence rules.

### 2.4 The w64 library (exact op set + algorithms)

`bootstrap/qmes-w64.scm`, pure Scheme over w32 prims. Target semantics:
**amd64 C `long` as M2-Planet compiles math.c** — wrap mod 2^64, arithmetic
right shift for signed, and shift counts masked `& 63` (amd64 SHL/SAR mask
counts; math.c `ash` compiles to those instructions).

| op | algorithm |
|---|---|
| `w64-add hi1 lo1 hi2 lo2` | `lo = w32-add lo1 lo2`; `carry = (w32-ult? lo lo1) → 1`; `hi = hi1+hi2+carry` |
| `w64-sub` | borrow via `(w32-ult? lo1 lo2)` |
| `w64-neg` | `w64-sub 0 0 hi lo` |
| `w64-mul` | 16-bit limbs: split each word with `w32-shr _ 16` / `w32-and _ 0xFFFF`; 16×16 products fit w32; accumulate the low 4 limbs (≈10 `w32-mul`s), discard overflow |
| `w64-udivmod` → `(q-hi q-lo . r-hi r-lo)` as two pairs or four globals | three cases: (a) divisor hi=0 ∧ lo<2^16 → long division in 16-bit chunks: fold the four 16-bit limbs of the dividend through `w32-uquot/w32-urem` (each partial dividend `r·2^16+limb < 2^32`); (b) divisor exactly 2^32 (hi=1, lo=0) → word move (q = 0:hi, r = 0:lo); (c) general → 64-iteration shift-subtract (correct, slow, corpus-rare) |
| `w64-and/or/xor/not` | per half |
| `w64-shl n c`, `w64-sar n c` | `c ← c & 63`; if c≥32 shift crosses halves (`hi = lo << (c−32)`, `lo = 0` / `lo = hi >> (c−32)`, `hi = sign`), else combine `w32-shl/shr/sar` with the 32−c carry-over (c=0 must not shift by 32 — guard it) |
| `w64-eq?` | both words |
| `w64-slt?` | signed: `hi1 < hi2` (w32-lt?) else if equal `lo1 <u lo2` (w32-ult?) |
| `w64-zero?`, `w64-neg?` | trivial |

### 2.5 Runtime prims: not now, and the exact escape hatch

Decision: **no new prims**. Adding prims means regenerating
`bootstrap/rsc-runtime.qf1` + `asm-runtime.flat` and re-verifying the closed
Stage-4 rsc fixpoint and asm.elf — real cost, zero proven need. The
interpreted hot path (dec->hex per immediate = `number->string _ 16` =
divmod by 16 → case (a), 4 w32 steps) adds small constant work per digit on
top of interpretation overhead that already dominates.

If S8.1 measurement (hello-64 + one big unit) projects the F1-64 sweep above
~2 h wall (i386 was ~16 min, expect 1.5–3×): add exactly two prims to
generate_rsc_runtime.py Part A — `w32-mulhi` (EDX of MUL) and `w32-divmod64`
(EDX:EAX ÷ r/m32 → q,r; caller guarantees hi<divisor, which case (a)'s
recurrence does) — then re-run the Stage-4 fixpoint + asm.elf validation
suite in the same commit. Default: skip.

---

## 3. qmes-64 = build variant via override file (one interpreter source)

### 3.1 Mechanism

rsc compiles top-level `define`s into ordered startup assignments to GV
cells; call sites load through the GV (bootstrap/sc1.scm:115-123, 311). Two
defines of the same name ⇒ last assignment wins for every subsequent call.
The one obstacle is that `qmes.scm` *ends with* `(qmain)` (last line), so an
appended override would run too late. Therefore:

- **Prep (i386-neutral):** move the final `(qmain)` line into new
  `bootstrap/qmes-main.scm`; `build-qmes.sh` compiles
  `cat rsc-prelude.scm qmes.scm qmes-main.scm`. The concatenation is
  byte-identical to today's input ⇒ `qmes.elf` is bit-identical (gate:
  sha256 before/after).
- **Variant:** `QMES64=1 tools/build-qmes.sh` compiles
  `cat rsc-prelude.scm qmes.scm qmes-w64.scm qmes-main.scm` → `qmes64.qfasm`
  → asm.elf → `./qmes64.elf`. (qmes-64 is still an **i386 process**; asm.elf
  needs no changes; only the *interpreted numbers* are 64-bit.)
- **Lock the semantics first:** add corpus test `tests/cases/rsc-redefine`
  (`(define (f) 1) (define (f) 2) (display (f))` → `2`, plus a
  mutually-recursive pair to prove late binding through GV). If rsc ever
  rejects duplicate defines, fallback = split the number layer into
  `qmes-num32.scm`/`qmes-num64.scm` selected by the build script (more
  churn, same shape) — but the GV architecture makes rejection unlikely.

### 3.2 Hookification prep commit (makes the override file small)

Some 32-bit payload touches sit inside large functions and must become named
seams first (this commit changes qmes.elf bytes, so re-run `make
fixpoint-verify` + `make boot-ladder` + scaffold sweep; all output-based
gates, all cheap):

1. `b-lognot` — currently inline in the vm builtin dispatch
   (qmes.scm:2385); extract to a top-level function like its 12 siblings.
2. `emit-tnumber fd x` — hook at the printer's TNUMBER arm (qmes.scm:2011,
   today `(emit-number fd (num-fixnum x))`).
3. `num=? x y` — hook at the four value-equality sites (qmes.scm:442
   `qassq-value`, 1928 `memq-value`, 1983 `equal2` TNUMBER arm; 1980's TCHAR
   arm may share it).
4. `copy-num e` — hook at qmes.scm:460 (the TNUMBER re-box in the vm).

**Acceptance invariant** (mechanical, greppable): after prep, every
occurrence of `num-value`, `num-fixnum`, `make-number-w`, `make-number-2w`,
`raw-ref … 2` on TNUMBERs outside the number layer is either (a) an
index/fd/len consumer of `num-value`/`num-fixnum` (lo-word truncation is
correct there), or (b) inside a function that appears in the §3.3 override
list. Record the census (`grep -n "num-value\|num-fixnum\|make-number-w"
bootstrap/qmes.scm`, ~91 hits today) in the PR.

### 3.3 The override set (complete contents of qmes-w64.scm)

- w64 library of §2.4 (new names, no collisions).
- `make-number-2w`, `num-hi`, override `make-number-w` (§2.2).
- Overrides of the 13 math builtins + their loops
  (qmes.scm:2066-2172 region): `b-plus b-minus b-is b-mult b-div b-modulo
  b-ash b-less b-greater b-logand b-logior b-logxor b-lognot` — **same
  transliteration discipline as the 32-bit originals**: each mirrors its
  math.c function line-by-line (`b-modulo` keeps the `while (n<0) n+=w`
  raise loop, at most one iteration for n ≥ −2^63+…; `b-div` keeps
  unsigned-magnitude + sign-fold; `b-ash` = shl / sar with §2.4 masking).
- `parse-number`/`parse-digits` (decimal, wrap mod 2^64) and
  `reader-read-radix` via a new `radix-loop64` (qmes.scm:1409-1412). Do
  **not** touch the 32-bit `radix-loop` — the `\xHH` string-escape and
  `#\xNN` char paths (qmes.scm:1309, 1342) keep using it.
- `emit-tnumber` (decimal, sign + w64-udivmod by 10), `num=?` (both words),
  `copy-num` (both raw words).
- `(bind-value (intern-rsc "%arch") (string-rsc "x86_64"))` — override the
  binder or rebind; today's value is "x86" at qmes.scm:1149. Everything else
  in the environment (%version, MES_VERSION) is unchanged.

Nothing else in qmes.scm is width-sensitive: cell indices, byte-pool
offsets, string lengths, port ids, stack slots are all < 2^30, and the hash
functions are two-byte-only (§1.3).

---

## 4. The x86_64 reference and the F-64 gates

### 4.1 `bin/mes-m2-64` (S7.0)

Parameterize `tools/build-mes-reference.sh` (it already transcribes
kaem.run's variable-driven file list) with the kaem.x86_64 settings
(third_party/mes/kaem.x86_64:23-26):

```
cc_cpu=x86_64  mes_cpu=x86_64  stage0_cpu=amd64  blood_elf_flag=--64
```

Concretely: `M2-Planet --architecture amd64 -D __x86_64__=1`, sources swap
`${mes_cpu}` dirs (`lib/linux/x86_64-mes-m2/{crt1.c,crt1.M1,_exit.c,_write.c,
syscall.c}`, `include/linux/x86_64/syscall.h` — all present in the tree);
`blood-elf --64 --little-endian`; `M1 --architecture amd64 -f
lib/m2/x86_64/x86_64_defs.M1 -f lib/x86_64-mes/x86_64.M1 -f
lib/linux/x86_64-mes-m2/crt1.M1 …`; `hex2 --architecture amd64
--base-address 0x1000000 -f lib/m2/x86_64/ELF-x86_64.hex2 …` →
`bin/mes-m2-64` (ELF64, runs natively on this x86_64 kernel).

**Feasibility verified on this machine (2026-07-08):** nixpkgs M2-Planet
lists `amd64` among its architectures; nixpkgs mescc-tools `M1` and `hex2`
both list `amd64`; `blood-elf` has `--64`. Same pinned nixpkgs versions
(m2-planet 1.13.1, mescc-tools 1.7.0) that produced the working i386
`bin/mes-m2`. Script form: `ARCH=x86_64 tools/build-mes-reference.sh` (keep
one script, two parameter blocks; default x86 output path unchanged).

Smoke gate: `mes-m2-64 -c '(display #x100000000)'` → `4294967296`;
`-c '(display (modulo -1 #x100000000))'` → `4294967295`;
`-c '(display (ash -1 -56))'` → `-1`.

**Why a 64-bit reference is mandatory, not optional:** §1.1 — the i386
mes-m2 cross-hosting `--arch=x86_64` crashes at the first negative
immediate. There is no shortcut.

Guile note: `guile --no-auto-compile -e '(@@ (mescc) main)'
third_party/mes/module/mescc.scm -- -S -m 64 --arch=x86_64 …` with
`GUILE_LOAD_PATH=third_party/mes/module:third_party/nyacc/module` works
(verified, §1.1) and is a fast *dev-loop oracle* for expected .s while
qmes-64 is under construction. It is **not** part of any gate (the gate
authority is mes-m2-64; Guile's bignums could in principle diverge where
`long` wraps).

### 4.2 Recorded 64-bit references (S7.0b)

The i386 recorded outputs do not transfer: any scaffold rung that exercises
word width prints differently under a 64-bit mes. Run
`record-mes-references.sh` and `gen-boot-cuts.sh`-driven gates against
`bin/mes-m2-64` into `tests/mes-references-64/` (+ sha256 manifest +
`tests/mes-reference-bootstatus-64.txt`), same rung set as i386, same
documented skips where the reference itself faults.

### 4.3 F1/F2/F3-64 — precise definitions

All three reuse the existing harness scripts with an `ARCH64` parameter
block; identical env pinning (`env -i`, `LANG=`, `%version=0.27.1`, fixed
MES_ARENA/MES_STACK, MES_PREFIX=build/mesroot, repo-relative `-o` canon
labels — the determinism contract of tools/mescc-fixpoint.sh:24-30, 128-135
verbatim).

- **F1-64** (`tools/mescc-fixpoint.sh` gains `compile64`/`f1-64`/`verify64`):
  the same 20 `mes_SOURCES` units, flags `-S -m 64 --arch=x86_64 -D
  HAVE_CONFIG_H=1 -I build/include-64 -I third_party/mes/include`, where
  `build/include-64/mes/config.h` is the same generated config.h and
  `build/include-64/arch/{kernel-stat,signal,syscall}.h` symlink
  `include/linux/x86_64/` (the i386 harness's ensure_env pattern,
  mescc-fixpoint.sh:77-84, with the x86 → x86_64 dir swap). Canon dir
  `build/fixpoint64/canon` (same repo-relative `-o` string for both hosts).
  Hosts: `bin/mes-m2-64` vs `./qmes64.elf`; per-unit `cmp`; commit
  `tests/mescc-references/fixpoint/f1-64.sha256`.
- **F2-64** (`tools/mescc-link.sh` `ARCH64`): `mes_cpu=x86_64`, CPPFLAGS
  `-m 64 --arch=x86_64 …`, crt1 from `lib/linux/x86_64-mes-mescc/crt1.c`,
  libdir `build/mescc-lib-64` (arch subdir `x86_64-mes`), driver host
  `bin/mes-m2-64`, link `-nostdlib --base-address=0x1000000 -lc -lmescc`.
  mescc itself invokes M1/blood-elf/hex2 (env M1/HEX2/BLOOD_ELF) and already
  selects `--64` / `x86_64.M1` / hex2 `amd64` from the machine bits
  (mescc/mescc.scm:245, 375, 383). libc built once under mes-m2-64; link the
  mes binary twice, from the mes-m2-64 F1 .s set and from the qmes-64 F1 .s
  set; `cmp` → `bin/mes-mescc64.{ref,qmes}`; commit the binary sha256.
- **F3-64**: `bin/mes-mescc64.qmes` is a native amd64 ELF64 — run it
  directly as the host for a third F1-64 sweep; all 20 .s must match
  `f1-64.sha256`. (Also pleasing: F3-64's host contains no M2-Planet
  ancestry — it is the qmes-lineage mes.)
- Wrapper `tools/fixpoint64.sh` + Makefile targets `fixpoint-64`,
  `fixpoint-verify-64` mirroring the i386 ones (self-enter
  `nix shell nixpkgs#mescc-tools`).

The i386 `make fixpoint` remains a standing gate and must be green at every
commit of this track (S7 prep is the only commit that touches shared code).

---

## 5. Staged plan

**S7.0 — reference first** (independent, do before any qmes edits):
`ARCH=x86_64` build-mes-reference → `bin/mes-m2-64` + §4.1 smoke; record
§4.2 references. Gate: smoke triple + mes-m2-64 reaches top-main from
build/mesroot. ~0.5 d.

**S7.1 — prep/hookify** (the only commit touching the i386 source path):
`(qmain)` → qmes-main.scm (byte-identical build proven by sha256), the four
hooks of §3.2, `tests/cases/rsc-redefine`. Gate: qmes.elf sha unchanged for
the split step; after hooks, scaffold sweep + `make boot-ladder` + `make
fixpoint-verify` green. ~0.5 d.

**S7.2 — w64 library + overrides**: `bootstrap/qmes-w64.scm` (§2.4 + §3.3),
build wiring (`QMES64=1`). Gate — **the torture matrix, before anything
else**: new `tests/mes-64/w64-ops.scm`, a scaffold script that prints every
math builtin (and `number->string` radix 2/8/10/16, `string->number`,
`#x/#b/#o` literals, `eqv?`/`assq` on numbers) applied over a corner matrix
{0, ±1, ±127, ±128, ±129, ±2^31±1, 2^32−1, 2^32, 2^32+1, ±2^62, LONG_MIN,
LONG_MAX} × shift counts {0,1,31,32,33,63,64,65}; run under qmes-64 and
mes-m2-64, byte-compare stdout. mes-m2-64 *defines* truth for every corner
(including LONG_MIN negation and count-masking) — this gate converts the
biggest risk into a table diff. 1–2 d.

**S7.3 — the ladder at 64**: full scaffold sweep + B0–B12 cut gates + boot-5
to top-main, qmes-64 vs the §4.2 recorded references. Gate: same rung score
as i386 (with the same documented reference-segfault skips). 0.5–1 d.

**S8.1 — F1-64**: hello.c/main.c first (measure wall time; invoke §2.5
escape hatch only if projection > ~2 h), then the 20-unit sweep; commit
f1-64.sha256. 1–2 d + compute.

**S8.2/S8.3 — F2-64 + F3-64**: §4.3; commit hashes; `make fixpoint-64`.
0.5–1 d + compute.

Total: ~4–7 d + compute, matching the roadmap's S7+S8 envelope.

---

## 6. Risks, ranked

1. **w64 semantic corners vs M2-Planet-amd64 math.c** (division
   sign-folding, modulo's raise loop, sar vs shr, shift-count masking,
   LONG_MIN edge): the failure mode is a silent one-byte .s divergence found
   hours into a sweep. Killed by the S7.2 torture matrix (differential,
   seconds, exhaustive over the corner lattice) — do not start S7.3 without
   it green.
2. **rsc redefinition assumption** (§3.1): locked by `rsc-redefine` before
   any override is written; cheap file-split fallback exists.
3. **Hidden width assumptions outside the number layer** (a `num-fixnum`
   consumer that mes-m2-64 would treat as a full long; `core:car`-on-number
   divergence §2.2): bounded by the grep census invariant (§3.2) plus the
   S7.3 ladder, which exercises the whole VM against a 64-bit truth.
4. **Sweep wall time** (interpreted w64): measured at S8.1 hello before
   committing to the sweep; two-prim escape hatch specified (§2.5) with its
   re-verification cost.
5. **Reference-build drift** (M2-Planet 1.13.1 amd64 vs mes 0.27.1
   kaem.x86_64 expectations): same pinned toolchain that built the working
   i386 reference; the §4.1 smoke isolates any breakage to S7.0 where it is
   cheap.

Non-risks, for the record: asm.elf needs no ELF64 backend (qmes-64 is an
i386 binary; M1/hex2 do all amd64 assembly, symmetrically for both hosts —
same trust argument as i386 F2); GC and cell arena are untouched by §2.2;
hash bucket order is width-independent (hash.c:28-37).
