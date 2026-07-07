# qmes VM design (P3a): the eval-apply state machine in rsc

This is the implementation design for replacing the recursive evaluator in
`bootstrap/qmes.scm` with a faithful transliteration of Mes's explicit-stack VM
(`third_party/mes/src/eval-apply.c`), targeting scaffold/boot 15–37 by
exit-status differential against `bin/mes-m2`. It extends
`docs/qmes-design.md` (value model) and `docs/mes-bootstrap-plan.md` §1.2/§3.
Everything below is grounded in the C source at the cited lines; where qmes
deliberately diverges (builtins, cell indices), the divergence is called out.

Conventions in pseudocode: all code is the rsc dialect
(define/lambda+rest/if/cond/let*/letrec/named-let/case/when/unless/do/and/or/
begin/quote/quasiquote/set!, rsc prims + rsc-prelude + P1 prims). A Mes SCM is
an rsc fixnum cell index. `cell-type`/`cell-car`/`cell-cdr`/`raw-ref`/
`raw-set!`/`alloc`/`qcons` are the existing arena accessors in qmes.scm.
Reference exit statuses: `bin/mes-m2` exits **0 on every scaffold/boot file
15–37** (verified 2026-07-07 by running them; `MES_BOOT=<abs path> ./bin/mes-m2`).

---

## 1. VM shape in rsc

### 1.1 The C machine being transliterated

`eval_apply()` (eval-apply.c:417-1028) is one function: four global registers
R0 (env), R1 (expression/value), R2 (scratch/saved datum), R3 (continuation
state) (mes.h:77-83), an explicit stack `g_stack_array` with index `g_stack`
growing **down** from `STACK_SIZE` (=20000, gc.c:60; `g_stack = STACK_SIZE`
initially, mes.c:37), and a dispatch chain at the `eval_apply:` label
(eval-apply.c:442-504) that compares R3 against the `cell_vm_*` TSPECIAL cells
and `goto`s the matching label. `R3 == cell_unspecified` means "return R1 to
the C caller" (eval-apply.c:501-502).

The 29 dispatched states, in the exact order of the C dispatch chain
(eval-apply.c:443-499) — keep this order, it is roughly frequency-sorted:

| # | state (constants in symbols.h:34-63) | label | printed name |
|---|---|---|---|
| 1 | cell_vm_evlis2 | evlis2 | `*vm-evlis2*` |
| 2 | cell_vm_evlis3 | evlis3 | `*vm-evlis3*` |
| 3 | cell_vm_eval_check_func | eval_check_func | `*vm-eval-check-func*` |
| 4 | cell_vm_eval2 | eval2 | `*vm-eval2*` |
| 5 | cell_vm_apply2 | apply2 | `*vm-apply2*` |
| 6 | cell_vm_if_expr | if_expr | `*vm-if-expr*` |
| 7 | cell_vm_begin_eval | begin_eval | `*vm:begin-eval*` |
| 8 | cell_vm_eval_set_x | eval_set_x | `*vm-eval-set!*` |
| 9 | cell_vm_macro_expand_car | macro_expand_car | `*vm:core:macro-expand-car*` |
| 10 | cell_vm_return | vm_return | `*vm-return*` |
| 11 | cell_vm_macro_expand_cdr | macro_expand_cdr | `*vm:macro-expand-cdr*` |
| 12 | cell_vm_eval_define | eval_define | `*vm-eval-define*` |
| 13 | cell_vm_macro_expand | macro_expand | `core:macro-expand` |
| 14 | cell_vm_macro_expand_lambda | macro_expand_lambda | `*vm:core:macro-expand-lambda*` |
| 15 | cell_vm_begin_expand_macro | begin_expand_macro | `*vm:begin-expand-macro*` |
| 16 | cell_vm_macro_expand_define | macro_expand_define | `*vm:core:macro-expand-define*` |
| 17 | cell_vm_begin_expand_eval | begin_expand_eval | `*vm:begin-expand-eval*` |
| 18 | cell_vm_call_with_current_continuation2 | call_with_current_continuation2 | (P4) |
| 19 | cell_vm_macro_expand_set_x | macro_expand_set_x | `*vm:core:macro-expand-set!*` |
| 20 | cell_vm_macro_expand_define_macro | macro_expand_define_macro | `*vm:core:macro-expand-define-macro*` |
| 21 | cell_vm_evlis | evlis | `*vm-evlis*` |
| 22 | cell_vm_apply | apply | **`core:apply`** |
| 23 | cell_vm_eval | eval | **`core:eval-expanded`** |
| 24 | cell_vm_eval_macro_expand_eval | eval_macro_expand_eval | `*vm:eval-macro-expand-eval*` |
| 25 | cell_vm_eval_macro_expand_expand | eval_macro_expand_expand | `*vm:eval-macro-expand-expand*` |
| 26 | cell_vm_begin | begin | `*vm-begin*` |
| 27 | cell_vm_begin_expand | begin_expand | **`core:eval`** |
| 28 | cell_vm_if | vm_if | `*vm-if*` |
| 29 | cell_vm_call_with_values2 | call_with_values2 | (P4) |

(`cell_vm_begin_read_input_file` exists as a symbol, symbol.c:65, but is never
dispatched — allocate the cell, no handler.) Three of these are *user-visible
values*: `core:apply`, `core:eval-expanded`, `core:eval` are the TSPECIAL cells
bound in the initial environment and applied as procedures (eval-apply.c:556-576)
— that is how `(core:apply f args)` in 2d-compose works.

Two labels are entered only by direct goto, never via R3:
`call_with_current_continuation` (from the apply state, TSYMBOL branch) and
`call_with_values`. They become plain procedures, not dispatch entries.

### 1.2 Rendering: one rsc procedure per state, tail calls for gotos

rsc has proper tail calls, so the rendering is mechanical:

- **Each label becomes a top-level rsc procedure `st-<label>`** taking no
  arguments and reading/writing the register globals. Every `goto lbl` in the
  C becomes a tail call `(st-lbl)`. No host-stack growth, because every state
  transition is in tail position — this is a hard rule (§4.4).
- **The `eval_apply:` dispatch label becomes `(vm-dispatch)`**, a cond chain
  over `r3` in the table order above. It is reached from exactly one place,
  `st-vm-return` (the C's only path back to `eval_apply:` is `goto vm_return`
  → pop → `goto eval_apply`), plus the initial entry from `qmain`.
- C locals inside a state body become `let*` locals of that state's procedure.
  This is sound because eval_apply's C locals **never survive a dispatch
  round-trip**: whenever the C pushes a frame and gotos another state, every
  local it later reads is re-derived from R1/R2 after return (verified for
  `begin`'s `x`, see §5.7; same for `begin_expand`, `apply`'s `t`/`cl`/…).
- Loop-with-embedded-label shapes (`begin`, `begin_expand`) split into a loop
  procedure + a re-entry state procedure that tail-calls back into the loop
  (§5.7, §5.9). The loop's accumulator rides as a procedure argument.

### 1.3 Registers: rsc top-level globals

R0–R3 are **four rsc top-level variables** `r0 r1 r2 r3`, mutated with `set!`,
plus `stkp` for `g_stack`:

```scheme
(define r0 0)     ; env        (SCM = fixnum cell index)
(define r1 0)     ; expression / value
(define r2 0)     ; scratch / saved datum
(define r3 0)     ; continuation state (a cell_vm_* cell index)
(define stkp 0)   ; g_stack: index into g-stack, grows down from STACK-SIZE
```

Chosen over a `regs` vector because: (a) every value is a fixnum, so a global
slot is already reset-safe (no host pointer); (b) `set!` on a top-level var is
one store in rsc codegen, no `vec-raw-*`/w32 boxing on the hot path; (c) the
transliteration reads like the C. (This supersedes the "slots of a small rsc
vector" sketch in qmes-design.md — globals are strictly simpler and equally
sound.)

Initialization mirrors `mes_g_stack` (mes.c:34-43): `stkp = STACK-SIZE`,
`r0 = <initial env>`, `r1 = r2 = r3 = (make-char 0)` (a TCHAR-0 cell).

### 1.4 The stack: a dedicated raw-word vector

`g_stack_array` becomes its own raw vector, **not** part of `g-cells` — Mes
also keeps it as a separate array at the end of the arena (gc.c:94), and a
separate vector keeps cell indices and stack indices from ever being confused:

```scheme
(define STACK-SIZE 20000)                     ; gc.c:60 default; MES_STACK later
(define g-stack (make-vector STACK-SIZE 0))   ; raw 32-bit words
(define (stack-ref i)    (w32->fixnum (vec-raw-ref g-stack i)))
(define (stack-set! i v) (vec-raw-set! g-stack i (w32-from-fixnum v)))
```

Every slot holds an SCM (fixnum cell index) — never a w32 payload, never a
host value. That makes the stack trivially reset-safe (§4) and makes the P4
continuation snapshot (`call/cc` copies `g_stack_array[g_stack..STACK_SIZE)`
into a TVECTOR, eval-apply.c:996-1010) a straight word copy.

### 1.5 Frames: gc_push_frame / gc_pop_frame (gc.c:685-712), GC_FRAME_SIZE 5

The C pushes downward: `[sp-1]=procedure(cell_f), [sp-2]=R0, [sp-3]=R1,
[sp-4]=R2, [sp-5]=R3; sp -= 5`. So a pushed frame occupies, at the *new* sp:

```
g-stack[stkp+0] = R3       ; continuation state to resume
g-stack[stkp+1] = R2
g-stack[stkp+2] = R1
g-stack[stkp+3] = R0
g-stack[stkp+4] = procedure   ; GC_FRAME_PROCEDURE = 4 (constants.h:51-52)
```

```scheme
(define (push-frame!)
  (if (< stkp 5) (qdie "STACK FULL"))         ; gc.c:687-688
  (stack-set! (- stkp 1) cell-f)              ; procedure slot, filled by apply
  (stack-set! (- stkp 2) r0)
  (stack-set! (- stkp 3) r1)
  (stack-set! (- stkp 4) r2)
  (stack-set! (- stkp 5) r3)
  (set! stkp (- stkp 5)))

(define (pop-frame!)                          ; gc_peek_frame + sp adjust
  (set! r3 (stack-ref stkp))
  (set! r2 (stack-ref (+ stkp 1)))
  (set! r1 (stack-ref (+ stkp 2)))
  (set! r0 (stack-ref (+ stkp 3)))
  (set! stkp (+ stkp 5)))
```

`push_cc` (eval-apply.c:206-216) — the *only* way states suspend into a
subcomputation. Note the exact register dance: the frame captures the caller's
R0/R1, the **new** R2 (`p2`, the datum the resumed state will need) and the
**new** R3 (`c`, the state to resume), while the machine continues with
`R1 = p1, R0 = a` and the caller's old R3:

```scheme
(define (push-cc! p1 p2 a c)
  (let ((x r3))
    (set! r3 c)
    (set! r2 p2)
    (push-frame!)
    (set! r1 p1)
    (set! r0 a)
    (set! r3 x)))
```

After the subcomputation reaches `vm_return`, the machine is: `r3 = c` (so
vm-dispatch enters state c), `r2 = p2`, `r1 = <result>`, `r0 = <saved r0>`.

`vm_return` (eval-apply.c:1023-1027):

```scheme
(define (st-vm-return)
  (let ((x r1))
    (pop-frame!)
    (set! r1 x))          ; result overrides the saved R1
  (vm-dispatch))
```

### 1.6 The dispatcher and the non-tail-subexpression pattern

```scheme
(define (vm-dispatch)
  (host-heap-reset! floor)                    ; §4 — the safepoint
  (cond
    ((= r3 cell-vm-evlis2)          (st-evlis2))
    ((= r3 cell-vm-evlis3)          (st-evlis3))
    ((= r3 cell-vm-eval-check-func) (st-eval-check-func))
    ((= r3 cell-vm-eval2)           (st-eval2))
    ((= r3 cell-vm-apply2)          (st-apply2))
    ((= r3 cell-vm-if-expr)         (st-if-expr))
    ((= r3 cell-vm-begin-eval)      (st-begin-eval))
    ((= r3 cell-vm-eval-set-x)      (st-eval-set-x))
    ((= r3 cell-vm-macro-expand-car)(st-macro-expand-car))
    ((= r3 cell-vm-return)          (st-vm-return))
    ; ... remaining states in the table order of §1.1 ...
    ((= r3 cell-unspec)             r1)       ; eval_apply returns R1
    (else (qdie "eval/apply unknown continuation"))))
```

The worked example the whole machine reduces to — evaluating `if`'s test
non-tail, then continuing (eval-apply.c:648-651, 977-994):

```scheme
;; eval sees (if . rest):  R1 := rest, goto vm_if
(define (st-vm-if)                            ; R1 = (test then [else])
  (push-cc! (cell-car r1) r1 r0 cell-vm-if-expr)  ; save (R0,R1,R2,R3'); eval test
  (st-eval))

(define (st-if-expr)                          ; R1 = test's value, R2 = (test then [else])
  (let ((x r1))
    (set! r1 r2)
    (cond
      ((not (= x cell-f))
       (set! r1 (cell-car (cell-cdr r1)))     (st-eval))     ; then, TAIL
      ((not (= (cell-cdr (cell-cdr r1)) cell-nil))
       (set! r1 (cell-car (cell-cdr (cell-cdr r1)))) (st-eval)) ; else, TAIL
      (else (set! r1 cell-unspec) (st-vm-return)))))
```

The branch evaluation is a plain `goto eval` with **no** push — the frame that
was on the stack when `st-vm-if` ran still names whatever the `if`'s own
continuation is. Proper tail calls fall out exactly as in the C.

---

## 2. Cell-model deltas vs the current qmes.scm

The P2 arena (one `g-cells` vector of `3*NCELLS` raw words, cell i = words
3i/3i+1/3i+2, `alloc` bump) is kept. Four upgrades are required first (edit E1,
§7):

1. **Strings/symbols get the Mes layout.** Mes: TSTRING/TSYMBOL/TKEYWORD have
   `car = length`, `cdr = <TBYTES cell>`; the TBYTES cell's payload is the
   bytes (string.c; mes.h car union `length`/`bytes`, cdr union `string`).
   qmes: a TBYTES cell is `[TBYTES | length | byte-offset into g-bytes]`, and
   TSTRING/TSYMBOL/TKEYWORD are `[T | length | tbytes-cell-index]`. The current
   P2 layout (`car = offset, cdr = len`) must migrate. Why now:
   `string_equal_p` compares via the string cell (string.c:66+), `eq_p` on
   keywords is `string_equal_p` (core.c:90-95), `hashq_` hashes the first two
   bytes of `cell_bytes (x->string)` (hash.c:19-33), `symbol->string` shares
   the TBYTES cell. One indirection everywhere beats a parallel scheme.
2. **The full fixed-cell set.** Transliterate `init_symbols_` (symbol.c:45-160)
   in the same order: cell-nil, cell-f, cell-t, cell-dot, cell-arrow,
   cell-undefined, cell-unspec, cell-closure, cell-circular; all 30
   `cell-vm-*` TSPECIALs (each carries its printed name as bytes — TSPECIAL
   cells have the string layout of item 1, and `hashq_` accepts TSPECIAL); all
   `cell-symbol-*` and `<cell:*>` type symbols. Each becomes an rsc global
   assigned at init. qmes need **not** reproduce Mes's numeric indices (they
   are never observable — only identities are), so interning happens in one
   pass (the C runs `init_symbols_` twice only because its hash table doesn't
   exist yet the first time, symbol.c:164-171; qmes keeps its linear
   `sym-table` intern list until the g_symbols hashq port, which is optional).
3. **Builtins: TFUNC grows an arity.** Mes builtins are TSTRUCTs holding a C
   function pointer + arity + name (builtins.c). qmes keeps the P2 adaptation —
   cell type TFUNC 20, `car = builtin-id` — and adds `cdr = arity` (−1 = n-ary)
   so `check_formals` (eval-apply.c:36-57, arity via the formals-is-TNUMBER
   branch) and `apply_builtin`'s arity dispatch (eval-apply.c:382-414)
   transliterate directly. The apply state tests `(= t TFUNC)` where the C
   tests `TSTRUCT && builtin_p` (eval-apply.c:524). This is invisible to
   scaffold exit statuses; revisit (real TSTRUCT builtins) only if a boot file
   is ever found to introspect builtins.
4. **New cell types now in play:** TCLOSURE 2, TKEYWORD 4, TMACRO 5, TVALUES 14
   (defer), TBINDING 15, TVECTOR 16, TREF 9, TSTRUCT 12, TBYTES 1, TPORT 8
   (defer). Use Mes's numeric type tags verbatim (constants.h:26-44) — the
   `<cell:*>` type-number bindings in the initial env expose them to Scheme
   (symbol.c:183-200), and 20-define-quote reads `<cell:char>`.
   Vectors/structs are contiguous cell runs: `make_vector_`/`make_struct`
   allocate a header cell (`car = length`, `cdr = index of first element
   cell`) plus `k` consecutive cells (vector.c:5-17, struct.c:5-28); elements
   are stored via `vector_entry` (wrap non-char/number in TREF, vector.c:59-64)
   and unwrapped on ref (vector.c:39-50) — transliterate that faithfully,
   `equal2_p` and `struct_ref_` depend on it.

Arena sizing for P3a: `NCELLS = 1000000` (3M words ≈ 12 MB of rsc byte arena —
fits the current 32 MiB; the 20e6-cell MES_ARENA parity matters only from P4
on and will need the runtime arena-constant bump flagged as plan-gap 11).
No literal in qmes source may exceed ~2^27 — 1000000 and 3000000 are fine.

---

## 3. Environments, closures, variables, modules

### 3.1 The two-level environment

Mes environments are **two-level**:

- **Lexical**: an alist in R0 of `(name . value)` handle pairs. Inside any
  lambda body, the *first* entry is the marker `(*closure* . env-tail)` — that
  is what `call_lambda` builds (eval-apply.c:150-157) and what the evaluator
  tests to decide global vs local define: `global_p = (R0->car->car !=
  cell_closure)` (eval-apply.c:676-678).
- **Global**: when `(current-module)` is `#f` (always true for scaffold 0x–4x;
  M1 = cell_f from mes.c:220 until the module system boots), globals live in
  **M0**, a hashq table mapping symbol → **variable** (module.c:60-75). M0 is
  built at startup from the builtin alist by `make_initial_module`
  (module.c:25-37).

Lookup (`lookup_binding`, eval-apply.c:218-230): `assq name R0` → if found,
wrap the handle pair in a TBINDING with `lexical_p = 1`; else
`current_module_variable (name, define_p)` → if a variable found (or created,
when `define_p` ≠ #f), wrap `(name . variable)` in a TBINDING with
`lexical_p = 0`; else `#f`. TBINDING cell: `car = handle`, `cdr = lexical_p`
(eval-apply.c:165-177). `lookup_value` (232-244): lexical → `cdr handle`;
global → `variable_ref variable`.

```scheme
(define (lookup-binding name define-p)        ; returns TBINDING cell or cell-f
  (let ((handle (assq-cell name r0)))
    (if (not (= handle cell-f))
        (make-binding- handle 1)
        (let ((var (current-module-variable name define-p)))
          (if (= var cell-f) cell-f
              (make-binding- (qcons name var) 0))))))

(define (current-module-variable name define-p)   ; module.c:60-75, M1=#f path
  (let ((var (hashq-ref- m0 name cell-f)))
    (if (and (= var cell-f) (not (= define-p cell-f)))
        (hashq-set!- m0 name (make-variable cell-undefined))
        var)))
```

(The M1-booted branch — standard_eval_closure etc., module.c:77-116 — is P3c/P4
work; leave a `qdie` guard.)

### 3.2 Variables and the struct/hash substrate

A **variable** is a TSTRUCT of length 4 — `[<variable>-record-type, printer,
'variable, value]`; `variable_ref` = `struct_ref_ (var, 3)`, `variable_set_x` =
`struct_set_x_ (var, 3, val)` (variable.c:39-69). A **hashq table** is a
TSTRUCT `[hash-table-type, printer, 'hashq-table marker?, size(TNUMBER),
buckets(TVECTOR)]` with `struct_ref_ 3 = size`, `struct_ref_ 4 = buckets`
(hash.c:49-60, make_hash_table_ hash.c:258-270; size 0 defaults to 100).
Buckets are assq alists; the hash is `(s[0]*37 + (s[1]? s[1]*43 : 0)) mod size`
over the symbol's bytes (hash.c:8-33). Port hash.c's `hashq_get_handle`,
`hashq_ref_`, `hashq_set_x`, `hashq_create_handle_x` — they are what M0,
`g_macros` (§6), and later the module system run on.

So the P3a dependency spine is: **vector.c → struct.c → hash.c → variable.c →
module.c(M1=#f) → lookup_binding** — five small leaf-code files, all ordinary
arena code, no VM interaction.

### 3.3 Closures and application

`make_closure_` (eval-apply.c:159-163): TCLOSURE cell, `car = cell-f`,
`cdr = ((*circular* . env) . (formals . body))`.

The apply state's TCLOSURE branch (eval-apply.c:530-541) — the proper tail
call — transliterated exactly, including the double-cdr on the captured env
(the closure drops the env's own head entry):

```scheme
;; inside st-apply, t = TCLOSURE case; f = (cell-car r1)
(let* ((cl      (cell-cdr f))                     ; ((*circular* . env) . (formals . body))
       (body    (cell-cdr (cell-cdr cl)))
       (formals (cell-car (cell-cdr cl)))
       (args    (cell-cdr r1))
       (aa      (cell-cdr (cell-cdr (cell-car cl)))))  ; cl->car->cdr, then ->cdr
  (check-formals f formals args)
  (let ((p (pairlis formals args aa)))
    ;; call_lambda (eval-apply.c:150-157): no push — tail call
    (set! r1 body)
    (set! r0 (qcons (qcons cell-closure p) p))
    (st-begin)))
```

`pairlis` (eval-apply.c:96-104) handles rest args structurally (formals not a
pair → bind the rest symbol to the remaining args):

```scheme
(define (pairlis x y a)
  (cond ((= x cell-nil) a)
        ((not (= (cell-type x) TPAIR)) (qcons (qcons x y) a))
        (else (qcons (qcons (cell-car x) (cell-car y))
                     (pairlis (cell-cdr x) (cell-cdr y) a)))))
```

(Host recursion here is fine: depth = number of formals. The rule is that only
*eval* recursion must go through the VM stack; leaf helpers bounded by data
shape — pairlis, equal2?, append2, expand-variable's inner walk — may use the
host stack.)

`check_formals` (eval-apply.c:36-57): flen = arity value if formals is TNUMBER
(builtin case) else `length__` (core.c:130-141, returns −1 for improper lists
— that is how rest-arg lambdas skip the count check); mismatch → `error`
(§3.5). `add_formals` (eval-apply.c:247-257) is used by expand_variable only.

### 3.4 define — the eval_define flow (eval-apply.c:673-761)

In `st-eval`, on `(define ...)`/`(define-macro ...)`:

- `global_p = (cell-car (cell-car r0)) != cell-closure`; `macro_p` from the
  keyword.
- Global pre-pass: for `define-macro`, ensure a g_macros handle exists
  (`macro_get_handle` → if #f, `macro_set_x name cell-f`); for plain `define`,
  `lookup-binding name cell-t` — this **creates the M0 variable before the
  value is evaluated**, which is what lets mutually-recursive top-level
  defines and 26-begin-define-later resolve.
- `(define name expr)`: `push-cc! expr R2=r1 (qcons (qcons name name) r0)
  cell-vm-eval-define; (st-eval)`.
- `(define (name . formals) body...)`: rewrite to
  `(lambda formals body...)`; if `macro_p || global_p`, run
  `expand-variable body formals` first (§3.6); env for the eval is
  `p = pairlis (cadr r1) (cadr r1) r0` (self-alist of the definee, C line 718);
  `push-cc!` that lambda with state `cell-vm-eval-define`.
- `st-eval-define` (C 724-761): recompute global_p/macro_p from r0/r2 (they
  can be clobbered by inline defines during evaluation — the C comment);
  name = `(cadr r2)`, or its car when a pair. Then:
  - macro: `entry = macro_get_handle name; r1 = make-macro name r1;
    set-cdr! entry r1` (§6);
  - global: `set_x name r1 define_p=1`;
  - local: splice `(name . r1)` into the current lexical env *behind* the
    `*closure*` head entry, keeping the marker's cdr pointing at the extended
    tail (C 750-758: `aa = cons (cons name r1) nil; set-cdr! aa (cdr r0);
    set-cdr! r0 aa; set-cdr! (car r0) aa`) — this is what makes internal
    defines visible to sibling closures (26-define-define, 2f-*).
  - `r1 = cell-unspec; (st-vm-return)`.

`set_x` (eval-apply.c:124-148): accepts a TBINDING or a name (lookup);
lexical → `set-cdr!` the handle; global → `variable_set_x` (unbound check when
`define_p = 0`). This variable indirection through M0 is **required** for
34-cdr-override-close / 36-closure-override / 35-closure-modify: a global
re-define finds the *same* variable cell every closure's lookup goes through.

### 3.5 error

`error` (core.c:150-163): look up `throw`; if defined, apply it (through the
VM — in qmes, build the application and tail-call st-apply); scaffold runs
have no `throw`, so: print key/args to stderr, `(exit 1)`. All 15–37
references exit 0, so any error path taken is already a divergence; exact
status beyond "nonzero, printed" doesn't matter yet.

### 3.6 expand_variable — binding memoization (eval-apply.c:280-379)

`begin_expand` calls `expand_variable (form, cell-nil)` on every top-level
form, and global/macro function-defines call it on their bodies. It rewrites
free TSYMBOL occurrences **in place** into TBINDING cells (creating M0
variables for still-undefined names via `lookup_binding (a, cell_t)` — the
forward-reference mechanism), skipping quoted forms, formals
(`formal_p`/`add_formals`), and `current-environment`.

It is written against the global registers with an explicit worklist in R3 and
a `gc_push_frame`/`gc_pop_frame` bracket (eval-apply.c:358-379). Transliterate
exactly that way — it reuses the machinery we already have:

```scheme
(define (expand-variable x formals)
  (push-frame!)
  (set! r1 x) (set! r2 formals) (set! r3 cell-nil)
  (expand-variable- 1)
  (let loop ()
    (when (= (cell-type r3) TPAIR)
      (set! r1 (cell-car (cell-car r3)))
      (set! r2 (cell-cdr (cell-car r3)))
      (set! r3 (cell-cdr r3))
      (expand-variable- 0)
      (loop)))
  (pop-frame!)
  cell-unspec)
```

`expand-variable-` (C 280-356) is two sequential `while` loops over r1 —
render as named lets; it only reads/writes r1/r2/r3 and calls
`lookup-binding`, `add-formals`, `formal_p`. Note `st-eval` must then handle
TBINDING both as `R1` itself (C 785-798) and as the *car* of an application
(C 622-633, deref before dispatching on the operator).

Staging note: the VM is semantically workable *without* expand_variable (all
lookups fall through to the symbol path) — every 15–37 test except none is
known to require memoization for its exit status — but it is ~90 lines, it is
the mechanism the reference actually runs, and skipping it is a fidelity risk
that would surface as impossible-to-bisect divergence later. Implement it in
the same edit as M0/TBINDING (E4, §7).

---

## 4. host-heap safepoint integration

### 4.1 Placement: one reset per dispatch

`(host-heap-reset! floor)` is the **first expression of `vm-dispatch`** and
appears nowhere else in the VM. vm-dispatch is entered exactly at every frame
pop (st-vm-return) — i.e. at every subexpression completion — so per-step host
garbage (rsc arg-list pairs, env frames, w32 boxes made by `raw-ref`
round-trips) is reclaimed at the highest safe frequency. `host-heap-reset!` is
a bump-pointer store: O(1), so no batching counter is needed.

### 4.2 Soundness argument (extends qmes-design.md)

At the moment the reset runs inside vm-dispatch:

- Durable VM state is: `g-cells`, `g-bytes`, `g-input`, `g-stack`, `g-chunk` —
  vectors/strings allocated **before** the mark (their payloads live in rsc's
  *byte* arena, which the reset never touches, and their handles sit in
  top-level global slots, which are pre-mark storage) — plus `r0-r3`, `stkp`,
  `m0`, `g-macros-table`, all fixnums. The VM stack lives in `g-stack` as raw
  words. **Nothing durable points into the host cell heap.**
- The continuation of the reset is: read fixnum globals, tail-call an `st-*`
  procedure. vm-dispatch has no parameters and no free lexical variables, so
  its own (now-freed) env frame is never read after the reset. This is the
  discipline rule: **the reset lives only at the top of a zero-argument
  procedure that touches nothing but top-level globals.**
- All `st-*` state procedures reach vm-dispatch **only in tail position**
  (only via `st-vm-return`). Therefore no `st-*` local (which lives in a host
  env frame) is ever live across a reset. `st-vm-return`'s own local `x` is
  consumed *before* its tail call to vm-dispatch.

### 4.3 The one host value that crosses the reset: `floor` itself

`(host-heap-mark)` returns a **w32 box** — a host-heap object allocated *at*
the mark. The established qmes.scm pattern handles this:
`(set! floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))` — `floor` is
mark+64, and the 64-byte pad below `floor` protects the `floor` w32 box (and
the mark's own transient cells) from being reused. Keep exactly this idiom and
this comment; it is the single deliberate exception to "no host value survives
a reset", and it is safe because the pad region is never re-allocated.

Audit list of places a host value must NOT be held across a reset (each is a
review item for the implementing agent):

1. Builtins run entirely between two dispatches (inside `st-apply`'s TFUNC
   branch) — they may use host locals/strings freely but must persist results
   only into the arena (e.g. `string-append` copies into `g-bytes`, never
   stores an rsc string).
2. The reader runs at boot, **before** the mark is taken (§6.3 main order), so
   its interaction is moot for P3a. When P3b adds `primitive-load`/ports
   (reading after boot), the read buffers are the pre-allocated globals
   `g-input`/`g-chunk`, so the property is preserved.
3. Debug printing helpers must not build host strings that are cached in
   globals. (Print through `g-bytes`-backed buffers or direct `sys-write`.)
4. A debug switch `qmes-no-reset` (a global tested in vm-dispatch) turns the
   reset off, for bisecting suspected reset bugs: any behavior difference with
   the switch flipped is a discipline violation.

### 4.4 The tail-call rule

Restated as the invariant the implementer must keep: **`st-*` procedures and
`vm-dispatch` may only ever be invoked in tail position.** Helpers (pairlis,
lookup-binding, equal2?, printers, the reader) must never call into any
`st-*`/vm-dispatch. Two C functions that *do* re-enter the evaluator —
`error` via `apply` of `throw`, and `current_module_variable`'s eval-closure
branch (module.c:94-99) — are P3b/P4 items; both re-enter via tail-calling
st-apply with a pushed `cell-vm-return`-style frame, or are guarded off.

---

## 5. State catalog: transitions and pseudocode

Notation: `push-cc!(p1, p2, a, c); → S` means tail-call state S after the
push; `→ S` alone is a plain tail call. All are direct transliterations of
eval-apply.c:506-1027; C line refs given. §1.6 already gave vm_if/if_expr and
§1.5 vm_return.

### 5.1 evlis / evlis2 / evlis3 (C 506-518)

```scheme
(define (st-evlis)                 ; R1 = arg list
  (cond ((= r1 cell-nil) (st-vm-return))
        ((not (= (cell-type r1) TPAIR)) (st-eval))   ; improper tail
        (else (push-cc! (cell-car r1) r1 r0 cell-vm-evlis2)
              (st-eval))))
(define (st-evlis2)                ; R1 = head value, R2 = original list
  (push-cc! (cell-cdr r2) r1 r0 cell-vm-evlis3)
  (st-evlis))
(define (st-evlis3)                ; R1 = evaluated tail, R2 = head value
  (set! r1 (qcons r2 r1))
  (st-vm-return))
```

### 5.2 apply (C 520-610)

```scheme
(define (st-apply)                 ; R1 = (proc . evaluated-args)
  (stack-set! (+ stkp 4) (cell-car r1))   ; current frame's GC_FRAME_PROCEDURE
  (let* ((f (cell-car r1)) (t (cell-type f)))
    (cond
      ((= t TFUNC)                                       ; C: TSTRUCT+builtin_p
       (check-formals f (make-number-fx (func-arity f)) (cell-cdr r1))
       (set! r1 (apply-builtin f (cell-cdr r1)))         ; ordinary rsc dispatch
       (st-vm-return))
      ((= t TCLOSURE) ...)                               ; §3.3 — tail into st-begin
      ((= t TCONTINUATION) (qdie "call/cc: P4"))         ; C 543-555
      ((= t TSPECIAL)
       (cond ((= f cell-vm-apply)                        ; (core:apply f args)
              (push-cc! (qcons (cadr- r1) (caddr- r1)) r1 r0 cell-vm-return)
              (st-apply))
             ((= f cell-vm-eval)                         ; (core:eval-expanded e env)
              (push-cc! (cadr- r1) r1 (caddr- r1) cell-vm-return)
              (st-eval))
             ((= f cell-vm-begin-expand)                 ; (core:eval e env)
              (push-cc! (qcons (cadr- r1) cell-nil) r1 (caddr- r1) cell-vm-return)
              (st-begin-expand))
             (else (check-apply cell-f f) (fall-through))))
      ((= t TSYMBOL)
       (cond ((= f cell-symbol-call/cc) (qdie "call/cc: P4"))   ; C 580-584
             ((= f cell-symbol-call-with-values) (qdie "P3b"))  ; C 585-589
             ((= f cell-symbol-current-environment)
              (set! r1 r0) (st-vm-return))
             (else (fall-through))))
      ((= t TPAIR)                                       ; ((lambda ...) args...)
       (if (= (cell-car f) cell-symbol-lambda)
           (let* ((formals (cell-car (cell-cdr f)))
                  (body    (cell-cdr (cell-cdr f)))
                  (p       (pairlis formals (cell-cdr r1) r0)))
             (check-formals r1 formals (cell-cdr r1))
             (set! r1 body)
             (set! r0 (qcons (qcons cell-closure p) p))  ; call_lambda(body,p,p)
             (st-begin))
           (fall-through)))
      (else (fall-through)))))
;; fall-through (C 609-610): evaluate the operator, then re-apply
;;   (push-cc! (cell-car r1) r1 r0 cell-vm-apply2) (st-eval)
(define (st-apply2)                ; C 611-614: R1 = operator value, R2 = old (op . args)
  (check-apply r1 (cell-car r2))
  (set! r1 (qcons r1 (cell-cdr r2)))
  (st-apply))
```

(`fall-through` is written out inline in both spots, not a shared procedure,
to keep the tail property obvious. `check-apply` = C 59-94, error on
non-applicable types.)

### 5.3 eval (C 616-802)

Structure of `st-eval` on `(cell-type r1)`:

- **TPAIR**: let `c = (cell-car r1)`; if `c` is TBINDING, deref it into the
  car in place (C 622-633; unbound → error). Then:
  - `c = quote` → `r1 := (cadr r1)`; → st-vm-return
  - `c = begin` → → st-begin
  - `c = lambda` → `r1 := (make-closure- (cadr r1) (cddr r1) r0)`; → st-vm-return
  - `c = if` → `r1 := (cdr r1)`; → st-vm-if
  - `c = set!` → `push-cc!((caddr r1), r1, r0, cell-vm-eval-set-x)`; → st-eval
  - `c = cell-vm-macro-expand` (the TSPECIAL `core:macro-expand`) →
    `push-cc!((cadr r1), r1, r0, cell-vm-eval-macro-expand-eval)`; → st-eval
  - `c = define | define-macro` → the eval_define entry flow (§3.4)
  - otherwise (application): `push-cc!((car r1), r1, r0,
    cell-vm-eval-check-func)`; gc_check (no-op P3a); → st-eval
- **TSYMBOL**: self-return for `current-environment`, `begin`,
  `call-with-current-continuation` (C 774-781); else
  `r1 := assert-defined(r1, lookup-value r1)`; → st-vm-return
- **TBINDING**: deref (lexical → handle cdr; global → variable-ref); unbound →
  error; → st-vm-return (C 785-798)
- **TBROKEN_HEART**: error (P4 concern)
- else (numbers, strings, chars, specials, closures, vectors —
  self-evaluating, this is how 2g's vector literal "runs"): → st-vm-return

The three continuation states hanging off eval:

```scheme
(define (st-eval-set-x)            ; C 657-659: R1 = value, R2 = (set! name expr)
  (set! r1 (set-x (cadr- r2) r1 0))
  (st-vm-return))
(define (st-eval-check-func)       ; C 766-768: R1 = operator value, R2 = whole form
  (push-cc! (cell-cdr r2) r2 r0 cell-vm-eval2)
  (st-evlis))
(define (st-eval2)                 ; C 769-771: R1 = evaluated args, R2 = form
  (set! r1 (qcons (cell-car r2) r1))   ; NOTE: (car r2) = memoized/deref'd operator?
  (st-apply))                          ; no — C uses R2->car, the *un*-evaluated op?
```

Careful: C eval2 is `R1 = cons (R2->car, R1)` where R2 is the original form —
but eval_check_func pushed `p2 = R2 = <form>` and the operator *value* came
back in R1 at check_func, which immediately re-pushed with p1 = args. Read the
C once more when implementing: at `eval2`, `R2->car` is the original operator
position — which apply2-style application would re-evaluate. It works in C
because `eval_check_func` is pushed with `(R1->car, R1, ...)`: at eval2 the
*applied* list is `cons (R2->car, R1)` and the subsequent `goto apply` hits
the fall-through → apply2 path for non-value operators, while TCLOSURE/TFUNC
operator *cells* stored by expand_variable/TBINDING memoization apply
directly. Transliterate literally (`(cell-car r2)`), do not "fix" it.

### 5.4 eval_macro_expand_eval / _expand (C 661-670)

```scheme
(define (st-eval-macro-expand-eval)    ; R1 = evaluated arg of (core:macro-expand e)
  (push-cc! r1 r2 r0 cell-vm-eval-macro-expand-expand)
  (st-macro-expand))
(define (st-eval-macro-expand-expand)  (st-vm-return))
```

### 5.5 eval_define → §3.4.

### 5.6 macro_expand family (C 804-892)

`st-macro-expand`: R1 = form to expand.

- not a pair, or car = quote → st-vm-return.
- car = lambda → `push-cc!((cddr r1), r1, r0, macro_expand_lambda)`;
  → st-macro-expand. `st-macro-expand-lambda`: `(set-cdr!- (cell-cdr r2) r1)`;
  `r1 := r2`; → st-vm-return.  (Expands the body in place, skips formals.)
- car = define | define-macro → same shape with `macro_expand_define`;
  `st-macro-expand-define` additionally: if the (restored) form is a
  define-macro, `push-cc!(r1, r1, r0, macro_expand_define_macro)`; → st-eval —
  i.e. **define-macro forms are evaluated during expansion**, this is how
  macros defined earlier in a file are available to later forms in the same
  file. `st-macro-expand-define-macro`: `r1 := r2`; → st-vm-return.
- car = set! → same shape with `macro_expand_set_x` (expand only the value
  position).
- `(get-macro (car r1))` ≠ #f → `r1 := (qcons macro (cell-cdr r1))`;
  `push-cc!(r1, cell-nil, r0, cell-vm-macro-expand)`; → st-apply — apply the
  expander, then re-expand its output (fixpoint).
- portable-macro-expand / sc-expander-alist hook (C 852-874): transliterate;
  it is dead until boot-3x files define those names, and costs two lookups.
- otherwise: `push-cc!((car r1), r1, r0, macro_expand_car)`; → st-macro-expand.
  `st-macro-expand-car`: `set-car!- r2 r1`; `r1 := r2`; if `(cdr r1)` nil →
  st-vm-return; else `push-cc!((cdr r1), r1, r0, macro_expand_cdr)`;
  → st-macro-expand. `st-macro-expand-cdr`: `set-cdr!- r2 r1`; `r1 := r2`;
  → st-vm-return.

Note the walker **mutates the program cells in place** (set-car!/set-cdr! on
the read S-expression). qmes program cells live in the arena; fine.

### 5.7 begin / begin_eval (C 894-920)

The C `while` loop with the `begin_eval:` label inside. The loop accumulator
`x` (last value) never needs to survive a dispatch (it is re-assigned from R1
at `begin_eval` before any read). Rendering:

```scheme
(define (st-begin) (begin-loop cell-unspec))
(define (st-begin-eval)                    ; re-entry: R1 = value, R2 = remaining forms@
  (let ((x r1))
    (set! r1 (cell-cdr r2))
    (begin-loop x)))
(define (begin-loop x)                     ; x is a fixnum SCM — reset-safe by §4.4? no:
  (if (= r1 cell-nil)                      ;   begin-loop never crosses vm-dispatch with
      (begin (set! r1 x) (st-vm-return))   ;   x live — its only exits are tail calls.
      (begin
        ;; gc_check (no-op P3a)
        (if (and (= (cell-type r1) TPAIR)
                 (= (cell-type (cell-car r1)) TPAIR)
                 (= (cell-car (cell-car r1)) cell-symbol-begin))
            (set! r1 (append2 (cell-cdr (cell-car r1)) (cell-cdr r1))))
        (if (= (cell-cdr r1) cell-nil)
            (begin (set! r1 (cell-car r1)) (st-eval))          ; TAIL form
            (begin (push-cc! (cell-car r1) r1 r0 cell-vm-begin-eval)
                   (st-eval))))))
```

### 5.8 begin_expand / begin_expand_macro / begin_expand_eval (C 923-975)

Same loop shape as begin, used as the **top-level driver** (R3 initial state,
mes.c:242). Per form: splice nested begins; `push-cc!((car r1), r1, r0,
begin_expand_macro)`; → st-macro-expand. `st-begin-expand-macro`: if the
expansion changed the form (`r1 ≠ (car r2)`), store it and loop the macro
expansion again (C 941-946); else: pre-bind self-referential defines
(`lookup-binding (caadr form) cell-t` when the form is
`(define (name . _) . _)`, C 955-964); `expand-variable (car r1) cell-nil`;
`push-cc!((car r1), r1, r0, begin_expand_eval)`; → st-eval.
`st-begin-expand-eval`: like st-begin-eval, loop to the next form. Loop ends:
`r1 := x`; → st-vm-return.

Render with the same loop-procedure + two re-entry states pattern as §5.7
(`begin-expand-loop x`, re-entered from both `st-begin-expand-macro` — which
jumps back *into* the middle of the loop body (the C `goto begin_expand_while`)
— and `st-begin-expand-eval`). Give the mid-loop body its own procedure
`(begin-expand-body x)` so both the loop head and st-begin-expand-macro can
tail into it.

### 5.9 call/cc and call-with-values (C 996-1021) — P4 / P3b stubs

Design is fixed by the stack representation: continuation = TCONTINUATION cell
(`car = id, cdr = g_stack value`, gc.c:261) whose captured state is a TVECTOR
copy of `g-stack[stkp..STACK-SIZE)`; applying it copies the vector back to the
stack top and sets `stkp = STACK-SIZE − len` (C 543-555). Nothing else in this
design changes for P4 — that is the payoff of keeping the stack as raw words.
For P3a both entry points `qdie`.

---

## 6. define-macro / TMACRO / g_macros (designed now, lands P3b)

- **TMACRO cell**: `make_macro (name, x)` = `[TMACRO | x | name->string]`
  (gc.c:265-268): car = the expander (a TCLOSURE), cdr = the *TBYTES cell* of
  the name (for printing only).
- **g_macros**: a hashq table (`make_hash_table_ 0` → size 100, mes.c:222)
  mapping symbol → TMACRO-or-#f. `macro_get_handle` = hashq_get_handle;
  `get_macro` = handle ≠ #f → `(cell-car (cell-cdr handle))` — the *car* field
  of the stored TMACRO (the `->macro` union member is the car, mes.h:39);
  `macro_set_x` = hashq_set_x (eval-apply.c:180-203).
- Flow already wired by §3.4 (eval_define macro branch) and §5.6
  (macro_expand: get-macro hit → apply expander → re-expand). Because the
  *states* and the hash substrate land in P3a, P3b's define-macro is only:
  enable the eval_define macro branch + make_macro — no rework. That is the
  point of building hash.c into P3a.

### 6.1 Reader additions for P3a

Current qmes reader (qmes.scm:189-296) plus, for the 15–37 gate:

- `#:name` → TKEYWORD (reader.c:245-248: keyword = symbol bytes with TKEYWORD
  type; `eq?` on keywords is string equality so interning is not required —
  make a fresh TKEYWORD sharing the interned symbol's TBYTES).
- `#(...)` → read elements to `)`, `list->vector` (for 2g/11-vector).
- `` ` ``/`,`/`,@` → `(quasiquote x)`/`(unquote x)`/`(unquote-splicing x)`
  **as data** (2g contains `,(...)` inside a vector literal; it is never
  evaluated — the vector self-evaluates — so no quasiquote *evaluator* is
  needed for the gate).
- `#\c` with names `space`/`newline`/`tab` etc. → TCHAR (not needed by 15–37;
  cheap; do it when touching the reader).
- qmes *source* constraint reminder: the reader's own source cannot contain
  `#x`, `#(`, `...`-as-token, or block comments (sc1-reader limits).

### 6.2 Printer (display.c subset)

`core:display`/`core:write`/`core:display-error`/`core:write-error` builtins:
recursive printer over: TNUMBER (w32 → decimal via repeated
`w32-uquot`/`w32-urem` 10, sign via `w32-lt?` 0), TCHAR, TSTRING (display raw /
write with `"` and escapes), TSYMBOL/TSPECIAL/TKEYWORD (bytes; keywords prefix
`#:`), TPAIR (incl. quote sugar if desired — status-irrelevant), TCLOSURE
(`#<procedure ...>`), TFUNC, TVECTOR (`#(...)`), TBINDING/TSTRUCT (opaque).
Output via a small pre-mark byte buffer + `sys-write` to fd 1 or 2. Exit
statuses do not depend on output bytes, so imperfect fidelity here is
acceptable *for the gate* — but stdout/stderr diffs are the best divergence
debugging signal, so match display.c where cheap.

### 6.3 main / boot (mes.c:211-243 transliteration)

```scheme
(define (qmain)
  (init-cells)                        ; §2: fixed cells, symbols, type numbers
  (let ((a (mes-environment)))        ; mes.c:46-102 + init_symbols bindings:
                                      ;  self-bound specials (call/cc, call-with-values,
                                      ;  current-environment, lambda, quote, begin, if,
                                      ;  set!, define, define-macro), %version, %arch="x86",
                                      ;  %compiler, %argv, <cell:*> type numbers,
                                      ;  and the (*closure* . a) head entry (symbol.c:205)
    (let ((a2 (mes-builtins a)))      ; TFUNC bindings, §6.4 census
      (set! m0 (make-initial-module a2))   ; hashq(symbol → variable) over ALL entries
      (set! m1 cell-f)
      (set! g-macros-table (make-hash-table- 0))
      (open-and-slurp-boot)           ; existing qmes.scm code, unchanged
      (let ((program (read-all-forms)))    ; list of forms (read_boot, mes.c:177-183)
        (set! r0 (qcons (qcons cell-symbol-program program) cell-nil))
        (push-cc! program cell-unspec r0 cell-unspec)   ; mes.c:232
        (set! r3 cell-vm-begin-expand)                  ; mes.c:242
        (set! floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))  ; §4.3
        (vm-dispatch)                 ; runs to (= r3 cell-unspec) → returns R1
        (exit 0)))))                  ; mes.c:274: main returns 0
```

Mark placement: after *all* startup allocation (arena vectors, fixed cells,
env, M0, the slurped+parsed program) and before the first VM step. `%compiler`
in mes-m2 is `"m2c"`; bind qmes's to `"m2c"` as well for now and leave a
comment — it is status-invisible, and revisiting it is a P6/F1 determinism
question, not a P3a one.

### 6.4 Builtin census for the 15–37 gate

TFUNC ids + arities (arities from builtins.c:116-332 `init_builtin` calls):

| builtin | arity | needed by | notes |
|---|---|---|---|
| cons / car / cdr | 2/1/1 | everywhere | exist |
| list | −1 | 20-define-quote | exists |
| null? / pair? | 1 | 2c, 2d, 37 | trivial |
| eq? | 2 | 16 onward | core.c:85-113: identity, then TKEYWORD→string=, TCHAR/TNUMBER→value= (w32-eq?) |
| memq | 2 | 17-memq, 17-memq-keyword | lib.c, uses eq_p |
| equal2? | 2 | 17-equal2 | lib.c: identity, pair-recursive, string=, vector-wise |
| string=? | 2 | 17-string-* | string.c:66 (accepts keyword operands) |
| string-append | −1 | 17-string-append | copy bytes into g-bytes, new TSTRING |
| core:display / core:write | 1 | 15, 26, 2e… | §6.2 |
| core:display-error / core:write-error | 1 | 37 | fd 2 |
| exit | 1 | everywhere | exists (w32→status) |
| + − * / = < > | −1 | 2g defines, 16 | over w32 TNUMBER payloads |
| current-module | 0 | (17-open-input-string) | returns m1 (=#f) — 1 line, include |
| set-car! / set-cdr! | 2 | (internals already) | expose as builtins too |
| length | 1 | (cheap; check_formals uses length__ anyway) | |

Everything else in builtins.c (~174) stays unregistered until its scaffold
rung; unknown-name lookups already error correctly.

---

## 7. Migration plan from the current qmes.scm

The reader, byte pool, arena, slurp/open-boot, and exit path are kept. The
recursive `qeval`/`qevlis`/`qapply` (qmes.scm:302-341) are **deleted** in E3 —
`qapply`'s builtin dispatch does *not* need to become a VM state; it survives
as the ordinary procedure `apply-builtin` called from `st-apply`'s TFUNC
branch (builtins are leaves: they never recurse into eval; the ones that do —
core:apply, core:eval — are TSPECIAL cells handled *inside* the apply state,
§5.2, exactly as in C).

Each edit lands green on `tests/run.sh` + the mes-m2 differential for the
rungs listed. Old code is deleted in the same commit that replaces it (repo
policy).

- **E1 — cell model upgrade** (no VM yet; recursive evaluator still in).
  TBYTES string/symbol layout (§2.1); full fixed-cell + symbol init in
  init_symbols_ order (§2.2); TFUNC arity (§2.3); NCELLS/byte-pool bumps.
  Gate: 00–14 unchanged.
- **E2 — struct/vector/hash/variable substrate** (pure leaf code, no VM):
  make-vector-/vector-ref-/vector-set-/TREF wrap-unwrap; make-struct/
  struct-ref-/struct-set-; hashq family; make-variable/variable-ref/-set;
  make-initial-module; M0 wired as the global env *behind the existing
  recursive evaluator's* global-lookup (replace `genv` alist with M0
  variables; `env-define!` → `set-x define_p=1`). Gate: 00–14.
- **E3 — the VM.** g-stack + regs + push/pop/push-cc (§1); vm-dispatch;
  states: eval, evlis{,2,3}, apply{,2}, eval_check_func, eval2, vm_if,
  if_expr, begin, begin_eval, vm_return, eval_set_x, eval_define,
  macro_expand family (structural walk; get-macro returns #f — g_macros
  empty), begin_expand family **without** expand_variable (stub it to a
  no-op), eval_macro_expand_{eval,expand}. lookup-binding/lookup-value/set-x/
  pairlis/check-formals/check-apply/add-formals/length__/append2. main
  rewritten per §6.3 (delete run-forms; resets move into vm-dispatch). Delete
  qeval/qevlis/qapply. Gate: 00–14, plus 20–37 minus any expand_variable
  stragglers.
- **E4 — expand_variable + TBINDING.** §3.6, eval's TBINDING branches.
  Gate: 00–14 + 20–37 complete (30–37 closure/override semantics now exactly
  reference-shaped).
- **E5 — lib/display rung.** eq? full, equal2?, memq, string=?,
  string-append, printers, keywords in reader + TKEYWORD eq. Gate: 15, 16,
  17-equal2, 17-memq, 17-memq-keyword, 17-string-append, 17-string-equal.
- **E6 — vector literals.** `#(`, quasiquote-sugar-as-data, list->vector.
  Gate: 2g-vector, 11-vector. (Pure reader + already-built TVECTOR.)
- **Deferred out of P3a** (tracked for P3b): 17-open-input-string (TPORT,
  g_ports, string ports, read-string, set/current-input-port — the whole
  posix.c port layer); 38-simple-format; TVALUES/call-with-values;
  define-macro activation (make_macro — machinery already present after E3);
  call/cc (P4).

Suggested order E1→E2→E3→E4→E5→E6; E5 is independent of E4 and can swap
earlier if a quick 15–17 win is wanted after E3.

---

## 8. Scaffold gate: per-file requirements, 15–37

Reference: every file exits 0 under `bin/mes-m2`. "VM core" = E3 state set
(all files exercise begin_expand → macro_expand walk → eval, since the driver
runs every top-level form through them).

| file | beyond VM core: states/semantics | builtins | cells/reader | edit |
|---|---|---|---|---|
| 15-display | — | core:display | TSTRING out | E5 |
| 16-if-eq-quote | vm_if/if_expr (core) | eq? (TNUMBER value =), exit | — | E3+E5 |
| 17-equal2 | — | equal2?, core:write, exit | string= over TBYTES | E5 |
| 17-memq | — | memq, exit | — | E5 |
| 17-memq-keyword | — | memq (eq? keyword branch) | reader `#:` → TKEYWORD | E5 |
| 17-open-input-string | apply of builtins over port objs | open-input-string, set/current-input-port, read-string, current-module, core:*-error, equal2? | **TPORT + g_ports + string-port state — DEFER to P3b** | — |
| 17-string-append | — | string-append, string=?, exit | — | E5 |
| 17-string-equal | — | string=?, core:write, exit | — | E5 |
| 20-define{,-quoted,-quote} | eval_define global path; M0 variable | list, cons | 20-define-quote reads `<cell:char>` → type-number bindings in initial env | E3 |
| 21/22-define-procedure* | define→lambda rewrite; closure apply; check_formals | exit | TCLOSURE | E3 |
| 23/24/25-begin* | begin/begin_eval; append2 splicing; define-inside-begin at top level (begin_expand per-form) | exit | — | E3 |
| 26-begin-define-later | forward global ref: pre-created M0 variable (define pre-pass / expand_variable create-on-ref) | exit | — | E3–E4 |
| 26-define-define, 2f-* | **local** define path of eval_define (splice behind *closure* head) | core:display, core:write, list | — | E3 |
| 27/28/29/2a-lambda* | internal define + closure capture | eq?, exit | — | E3 |
| 2b/2c | global define of lambda; recursion via M0 variable | null?, cons, car, cdr, core:display | — | E3 |
| 2d-compose | **TSPECIAL core:apply in apply state**; rest-args via pairlis improper formals; length__ = −1 skip of arity check | null?, exit | — | E3 |
| 2d-define-lambda-set | set!/eval_set_x on global (variable_set_x) | exit | — | E3 |
| 2e/2f-* | builtins as first-class values (TFUNC in operand position); write of closures/builtins | core:display, core:write, exit | `#<procedure>` printing (status-neutral) | E3+E5 |
| 2g-vector | vector self-evaluation in eval's default branch | −, *, /, = (defines evaluated; map never called) | reader `#(` + `,`/`,@` as data; TVECTOR/TREF | E6 |
| 30/31-capture* | global define/closure | exit | — | E3 |
| 32/33/34/35/36 -override/-modify | **variable indirection**: redefine/set! must hit the same M0 variable earlier closures resolve through | core:display, exit | — | E3 (E4 for exact fidelity) |
| 37-closure-lambda | nested closures, user list ops | core:display-error, core:write-error, pair?, null?, eq? | — | E3+E5 |

Bigger-feature flags: **17-open-input-string** is the only 15–37 file pulling
in a whole subsystem (ports) — defer it to P3b alongside 38-simple-format.
**2g-vector** (with 11-vector) pulls vector cells + reader sugar — small since
hash tables already forced TVECTOR, but it is the natural last rung (E6).
Everything else is covered by the VM + module substrate + a dozen leaf
builtins.

---

## 9. Risks

1. **Reset discipline inside the trampoline** (top risk). A single `st-*`
   procedure holding a host local across a dispatch, or a helper tail-calling
   into a state, is a use-after-free that reproduces as data-dependent
   corruption. Mitigations: reset every dispatch from day one (fail fast, no
   lucky windows); the §4.3 audit list; the `qmes-no-reset` bisect switch; the
   §4.4 tail-call rule enforced by review (grep: `st-` calls may appear only
   in tail position of `st-*`/`vm-dispatch`/loop-procedure bodies).
2. **The define/begin_expand/expand_variable cluster** is the subtlest C in
   the file (in-place mutation of program cells, register clobber rules,
   create-on-reference). Transliterate literally — including the parts that
   look wrong (eval2's `R2->car`, the closure env double-cdr) — and lean on
   the per-rung differential to catch drift at the smallest reproducer.
3. **Perf**: ~28-compare dispatch + O(1) reset per return is fine; the M0
   hashq (2-char hash, 100 buckets) matches the reference's constant factors.
   Watch NCELLS/byte-arena headroom when boot files load (P3b), not now.
