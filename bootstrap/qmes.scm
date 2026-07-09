; qmes.scm — a Mes-core-compatible Scheme interpreter in the rsc dialect.
;
; Milestone P3a: a faithful-in-structure transliteration of GNU Mes's C core
; (third_party/mes/src/*.c).  P2 ran scaffold/boot 00-14 with a recursive
; evaluator; P3a (this file) grows the cell model (E1), the struct/vector/hash/
; variable substrate (E2), and replaces the recursive evaluator with Mes's
; explicit-stack VM (E3-E6) to run scaffold/boot 15-37.  See
; docs/qmes-vm-design.md and docs/qmes-design.md.
;
; Representation (per docs/qmes-design.md):
;   A Mes value ("SCM") is an rsc FIXNUM = an index into the cell arena.
;   The cell arena is one rsc VECTOR `g-cells` of 3*NCELLS raw 32-bit words,
;   accessed with vec-raw-ref / vec-raw-set!.  Cell i occupies words 3i (type),
;   3i+1 (car), 3i+2 (cdr).  Allocation is a bump counter `cell-free`; when the
;   arena fills, the S2 copy-up-slide-back collector (see "Garbage collection"
;   below) compacts g-cells + the byte pool.  host-heap-reset! is orthogonal:
;   it only reclaims rsc-level calling-convention garbage, never arena cells
;   (§2.4) — the two never interfere because the GC runs synchronously inside a
;   single VM dispatch and stores no host value into a qmes global.

; ===========================================================================
; Cell type tags (include/mes/constants.h)
; ===========================================================================
(define TCHAR 0)
(define TBYTES 1)
(define TCLOSURE 2)
(define TCONTINUATION 3)
(define TKEYWORD 4)
(define TMACRO 5)
(define TNUMBER 6)
(define TPAIR 7)
(define TPORT 8)
(define TREF 9)
(define TSPECIAL 10)
(define TSTRING 11)
(define TSTRUCT 12)
(define TSYMBOL 13)
(define TVALUES 14)
(define TBINDING 15)
(define TVECTOR 16)
(define TBROKEN-HEART 17)

; ===========================================================================
; The cell arena (one rsc vector of raw 32-bit words).
; Sizes are env-driven (D6): read MES_ARENA/MES_STACK/MES_MAX_STRING at startup
; (gc.c:67-87) and allocate g-cells / g-stack / the byte pool before the
; host-heap floor mark (§2.2).  Defaults match the pre-refit fixed sizes.
; ===========================================================================
(define ARENA-CELLS 1000000)                   ; MES_ARENA (cells)
(define g-cells 0)                             ; allocated in qmain
(define cell-free 0)

(define (raw-ref i off) (vec-raw-ref g-cells (+ (* 3 i) off)))
(define (raw-set! i off w) (vec-raw-set! g-cells (+ (* 3 i) off) w))

(define (cell-type i) (w32->fixnum (raw-ref i 0)))
(define (cell-car i) (w32->fixnum (raw-ref i 1)))
(define (cell-cdr i) (w32->fixnum (raw-ref i 2)))
(define (set-type! i v) (raw-set! i 0 (w32-from-fixnum v)))
(define (set-car! i v) (raw-set! i 1 (w32-from-fixnum v)))
(define (set-cdr! i v) (raw-set! i 2 (w32-from-fixnum v)))

; alloc-n: reserve n consecutive cells, return index of the first.
(define (alloc-n n)
  (let ((i cell-free))
    (set! cell-free (+ cell-free n))
    ; Unconditional cell-arena tripwire (C Mes asserts in make_cell; §3/#3).
    (if (> cell-free cell-cap)
        (begin (emit-str g-stderr ";;; ARENA OVERFLOW cell-free=") (emit-number g-stderr cell-free)
               (emit-str g-stderr " cap=") (emit-number g-stderr cell-cap)
               (emit-str g-stderr " in-gc=") (emit-number g-stderr in-gc-flag)
               (emit g-stderr 10) (exit 4))
        'ok)
    i))
(define cell-cap 999999999)                      ; = ARENA-CELLS+JAM-CELLS (qmain)
(define in-gc-flag 0)

; --- GC chunked host-heap reclamation (§2.4 follow-up: MesCC scale) ----------
; A single collection scans/relocates the whole live set (millions of cells);
; each cell processed conses transient host (rsc) w32 boxes.  Across one gc-
; call these overflow the ~512 MiB host cell heap and corrupt it.  Mirror the
; asm.scm discipline: the big loops (Cheney scan + flip cellcpy) are NILADIC
; self-tail loops with all cursor state in globals, and every GC-RESET-K cells
; the host heap is reset to a floor captured (mark+64) right before the loop.
; Nothing is pinned above that floor: the loop's single (migrating) frame lands
; in the 64-byte pad, and its return target sits below the mark.  g-cells holds
; raw words (vec-raw-set! stores the value, not a box ref), so relocated fields
; survive resets.  Loop cursors are fixnums (immediate); gc-floor's w32 box is
; below the floor (pad-protected), like the dispatch floor.
(define GC-RESET-K 256)
(define gc-floor #f)
(define gc-k 0)
(define gc-scan 0)                               ; niladic gc-loop cursor
(define gc-cc-j 0)                               ; niladic gc-cellcpy cursor
(define gc-cc-upto 0)
(define gc-dist 0)
(define (gc-tick!)
  (set! gc-k (- gc-k 1))
  (if (< gc-k 0)
      (begin (host-heap-reset! gc-floor) (set! gc-k GC-RESET-K))
      'ok))

; --- host pair-heap ceiling tripwire (§3/#3) --------------------------------
; The rsc host pair heap is a 512 MiB bump allocator with no bounds check in
; Cons; overflowing it silently smashes g-cells.  qmain records the base mark
; and a ceiling = base + cap (default 496 MiB, i.e. 16 MiB slack under the real
; 512 MiB span; overridable via QMES_HOSTHEAP_CAP_MIB for testing).  This cheap
; unsigned compare, called at the reader/nested-run re-entry points, turns an
; overflow into a clean one-line abort instead of silent corruption.
(define host-heap-base #f)
(define host-heap-ceiling #f)
(define (host-heap-guard!)
  (if (w32-ult? (host-heap-mark) host-heap-ceiling)
      'ok
      (begin (emit-str g-stderr ";;; qmes: host pair heap ceiling exceeded (overflow tripwire); aborting")
             (emit g-stderr 10)
             (exit 3))))

(define (alloc type a d)
  (let ((i (alloc-n 1)))
    (raw-set! i 0 (w32-from-fixnum type))
    (raw-set! i 1 (w32-from-fixnum a))
    (raw-set! i 2 (w32-from-fixnum d))
    i))

(define (qcons a d) (alloc TPAIR a d))
(define (acons key val alist) (qcons (qcons key val) alist))

; copy-cell!: copy the 3 raw words of cell `from` into cell `to`.
(define (copy-cell! to from)
  (raw-set! to 0 (raw-ref from 0))
  (raw-set! to 1 (raw-ref from 1))
  (raw-set! to 2 (raw-ref from 2)))

; TNUMBER cell: value (a w32 box) stored raw in the cdr word (offset 2); car=0.
(define (make-number-w w)
  (let ((i (alloc-n 1)))
    (raw-set! i 0 (w32-from-fixnum TNUMBER))
    (raw-set! i 1 (w32-from-fixnum 0))
    (raw-set! i 2 w)
    i))
(define (make-number-fx n) (make-number-w (w32-from-fixnum n)))
(define (num-value i) (raw-ref i 2))        ; -> w32 box
(define (num-fixnum i) (w32->fixnum (raw-ref i 2)))
; Number value-equality and value-copy seams (qmes-w64.scm widens them to
; compare / copy both the hi and lo words).  a and b are TNUMBER cell indices.
(define (num=? a b) (w32-eq? (num-value a) (num-value b)))
(define (copy-num e) (make-number-w (num-value e)))

; TCHAR cell: value (small fixnum, as w32) in cdr (offset 2); car=0.
(define (make-char n)
  (let ((i (alloc-n 1)))
    (raw-set! i 0 (w32-from-fixnum TCHAR))
    (raw-set! i 1 (w32-from-fixnum 0))
    (raw-set! i 2 (w32-from-fixnum n))
    i))
(define (char-value i) (w32->fixnum (raw-ref i 2)))

(define (make-ref x) (alloc TREF x 0))

; make_continuation (gc.c:258-262): TCONTINUATION cell [car = n, cdr = g_stack].
; The cdr placeholder is overwritten with the snapshot vector at capture (§3.1).
(define g-continuations 0)
(define (make-continuation n) (alloc TCONTINUATION n stkp))

; ===========================================================================
; Byte pool: symbol names and string contents (in rsc's byte arena)
; ===========================================================================
(define BYTE-POOL 16777216)                    ; 16 MiB; boot module files slurp here
; Paired two-space byte pool (FD §2.3): two equal-size string spaces, a current
; pool `g-bytes` (bump `byte-free`), and — during a collection — a target pool
; `gc-to-pool` (bump `gc-to-byte-free`).  gc-copy copies each TBYTES run into
; the target as its cell is copied; gc-flip swaps the roles.  Sharing is
; preserved because every string/symbol reaches bytes only through a TBYTES
; cell, and each TBYTES cell is forwarded exactly once.
(define g-bytes-a 0)                            ; allocated in qmain
(define g-bytes-b 0)
(define g-bytes 0)                              ; = current pool (a or b)
(define byte-free 0)
(define gc-to-pool 0)                           ; target pool during a collection
(define gc-to-byte-free 0)
(define gc-pressure 0)                          ; set when the pool is near full
(define BYTE-POOL-HI 15000000)                  ; pressure threshold (set in qmain)
(define (bytes-put! ch)
  (string-set! g-bytes byte-free ch)
  (set! byte-free (+ byte-free 1))
  (if (>= byte-free BYTE-POOL-HI) (set! gc-pressure 1) 'ok))
(define (copy-rsc-into-pool str)
  (let loop ((i 0) (n (string-length str)))
    (if (< i n)
        (begin (bytes-put! (string-ref str i)) (loop (+ i 1) n))
        'ok)))

; TBYTES cell: [TBYTES | length | byte-offset into g-bytes].
; TSTRING/TSYMBOL/TKEYWORD/TSPECIAL: [type | length | tbytes-cell-index].
(define (make-bytes-cell off len) (alloc TBYTES len off))
(define (make-strlike type off len) (alloc type len (make-bytes-cell off len)))
; Accessors over a strlike cell (string/symbol/keyword/special).
(define (strlike-len s) (cell-car s))
(define (strlike-bytes s) (cell-cdr s))               ; the TBYTES cell
(define (bytes-offset b) (cell-cdr b))                ; offset of a TBYTES cell
(define (strlike-offset s) (bytes-offset (strlike-bytes s)))
; First two bytes of a symbol/special's name (for hashq_ parity, unused now).
(define (strlike-byte0 s) (char->integer (string-ref g-bytes (strlike-offset s))))

; ===========================================================================
; Fixed cells and symbols (transliteration of init_symbols_, symbol.c:45)
; qmes need not reproduce Mes's numeric indices — only identities matter.
; ===========================================================================
(define cell-nil 0)
(define cell-f 0)
(define cell-t 0)
(define cell-dot 0)
(define cell-arrow 0)
(define cell-undefined 0)
(define cell-unspec 0)
(define cell-closure 0)
(define cell-circular 0)
(define cell-eof 0)          ; qmes-only reader sentinel

; VM state cells (TSPECIAL)
(define cell-vm-apply 0)
(define cell-vm-apply2 0)
(define cell-vm-begin 0)
(define cell-vm-begin-eval 0)
(define cell-vm-begin-expand 0)
(define cell-vm-begin-expand-eval 0)
(define cell-vm-begin-expand-macro 0)
(define cell-vm-call-with-current-continuation2 0)
(define cell-vm-call-with-values2 0)
(define cell-vm-eval 0)
(define cell-vm-eval2 0)
(define cell-vm-eval-check-func 0)
(define cell-vm-eval-define 0)
(define cell-vm-eval-macro-expand-eval 0)
(define cell-vm-eval-macro-expand-expand 0)
(define cell-vm-eval-set-x 0)
(define cell-vm-evlis 0)
(define cell-vm-evlis2 0)
(define cell-vm-evlis3 0)
(define cell-vm-if 0)
(define cell-vm-if-expr 0)
(define cell-vm-macro-expand 0)
(define cell-vm-macro-expand-car 0)
(define cell-vm-macro-expand-cdr 0)
(define cell-vm-macro-expand-define 0)
(define cell-vm-macro-expand-define-macro 0)
(define cell-vm-macro-expand-lambda 0)
(define cell-vm-macro-expand-set-x 0)
(define cell-vm-return 0)

; symbols
(define cell-symbol-lambda 0)
(define cell-symbol-begin 0)
(define cell-symbol-if 0)
(define cell-symbol-quote 0)
(define cell-symbol-define 0)
(define cell-symbol-define-macro 0)
(define cell-symbol-set-x 0)
(define cell-symbol-quasiquote 0)
(define cell-symbol-unquote 0)
(define cell-symbol-unquote-splicing 0)
(define cell-symbol-call-with-values 0)
(define cell-symbol-call-with-current-continuation 0)
(define cell-symbol-current-environment 0)
(define cell-symbol-car 0)
(define cell-symbol-cdr 0)
(define cell-symbol-not-a-pair 0)
(define cell-symbol-system-error 0)
(define cell-symbol-throw 0)
(define cell-symbol-unbound-variable 0)
(define cell-symbol-wrong-number-of-args 0)
(define cell-symbol-wrong-type-arg 0)
(define cell-symbol-record-type 0)
(define cell-symbol-standard-eval-closure 0)           ; B12: module.c fast paths
(define cell-symbol-standard-interface-eval-closure 0)
(define cell-symbol-hashq-table 0)
(define cell-symbol-variable 0)
(define cell-symbol-program 0)
(define cell-symbol-portable-macro-expand 0)
(define cell-symbol-sc-expander-alist 0)
(define cell-symbol-macro-expand 0)

(define sym-table 0)         ; init-phase interning list (before g-symbols built)
(define g-symbols 0)         ; D4: the obarray = hashq table size 500 (symbol.c)

; D1/D3 real type structs (builtins.c / hash.c / variable.c).  Symbols:
(define cell-symbol-builtin 0)      ; '<builtin>  (struct[2] tag of a builtin)
(define cell-symbol-buckets 0)      ; 'buckets
(define cell-symbol-size 0)         ; 'size
(define builtin-printer-sym 0)      ; 'builtin-printer (a symbol used as printer)
(define variable-printer-sym 0)     ; 'variable-printer
; stack.c symbols (make-frame/make-stack/frame-printer).
(define cell-symbol-procedure 0)    ; 'procedure
(define cell-symbol-frame 0)        ; 'frame
(define cell-symbol-stack 0)        ; 'stack
(define cell-symbol-frames 0)       ; 'frames
(define frame-printer-sym 0)        ; 'frame-printer
; The type structs themselves (make_*_type); GC roots for S2.
(define builtin-type-struct 0)
(define variable-type-struct 0)
(define hash-table-type-struct 0)

; Modules and macro table (E2)
(define m0 0)                ; initial module: hashq(symbol -> variable)
(define m1 0)                ; current module (cell-f until module system boots)
(define g-macros-table 0)    ; hashq(symbol -> TMACRO or cell-f)
(define env-alist 0)         ; the builtin/special alist M0 is built from

(define (bytes-eq-loop p1 p2 i n)
  (if (= i n)
      #t
      (if (char=? (string-ref g-bytes (+ p1 i)) (string-ref g-bytes (+ p2 i)))
          (bytes-eq-loop p1 p2 (+ i 1) n)
          #f)))
(define (bytes-equal? p1 l1 p2 l2)
  (if (= l1 l2) (bytes-eq-loop p1 p2 0 l1) #f))

(define (intern-scan lst start len)
  (if (= lst cell-nil)
      #f
      (let ((s (cell-car lst)))
        (if (bytes-equal? (strlike-offset s) (strlike-len s) start len)
            s
            (intern-scan (cell-cdr lst) start len)))))

; hash_cstring (hash.c:8): first two name bytes -> bucket index mod size.
(define (hash-cstring start len size)
  (let* ((b0 (char->integer (string-ref g-bytes start)))
         (b1 (if (> len 1) (char->integer (string-ref g-bytes (+ start 1))) 0))
         (h (+ (* b0 37) (if (and (not (= b0 0)) (not (= b1 0))) (* b1 43) 0))))
    (remainder h size)))
; scan an obarray bucket for an entry (key-string . symbol) matching the token.
(define (obarray-scan bucket start len)
  (if (not (= (cell-type bucket) TPAIR))
      cell-f
      (let* ((entry (cell-car bucket)) (key (cell-car entry)))
        (if (and (= (strlike-len key) len)
                 (bytes-equal? (strlike-offset key) len start len))
            (cell-cdr entry)
            (obarray-scan (cell-cdr bucket) start len)))))

; Intern a name whose bytes already occupy g-bytes[start, byte-free).  During
; init (g-symbols == 0) use the list; the reader uses the obarray (D4).
(define (intern start len)
  (if (= g-symbols 0) (intern-list start len) (intern-hash start len)))
(define (intern-list start len)
  (let ((found (intern-scan sym-table start len)))
    (if found
        (begin (set! byte-free start) found)   ; drop the duplicate copy
        (let ((s (make-strlike TSYMBOL start len)))
          (set! sym-table (qcons s sym-table))
          s))))
(define (intern-hash start len)
  (let* ((size (ht-size g-symbols))
         (h (hash-cstring start len size))
         (buckets (ht-buckets g-symbols))
         (bucket (vector-ref- buckets h))
         (found (obarray-scan bucket start len)))
    (if (not (= found cell-f))
        (begin (set! byte-free start) found)   ; drop the duplicate copy
        (let ((s (make-strlike TSYMBOL start len)))
          (vector-set-x- buckets h
                         (acons (retag TSTRING s) s
                                (if (= (cell-type bucket) TPAIR) bucket cell-nil)))
          s))))
; Build the obarray from the init-phase sym-table list and switch to it.
(define (build-obarray!)
  (let ((ht (make-hash-table- 500)))
    (obarray-populate ht sym-table)
    (set! g-symbols ht)))
(define (obarray-populate ht lst)
  (if (= lst cell-nil) 'ok
      (begin (obarray-insert ht (cell-car lst))
             (obarray-populate ht (cell-cdr lst)))))
(define (obarray-insert ht sym)
  (let* ((size (ht-size ht))
         (off (strlike-offset sym)) (len (strlike-len sym))
         (h (hash-cstring off len size))
         (buckets (ht-buckets ht))
         (bucket (vector-ref- buckets h)))
    (if (= (obarray-scan bucket off len) cell-f)
        (vector-set-x- buckets h
                       (acons (retag TSTRING sym) sym
                              (if (= (cell-type bucket) TPAIR) bucket cell-nil)))
        'ok)))

(define (intern-rsc str)
  (let ((start byte-free))
    (copy-rsc-into-pool str)
    (intern start (- byte-free start))))

; A fresh TSPECIAL fixed cell carrying `name` as bytes.
(define (special-rsc str)
  (let ((start byte-free))
    (copy-rsc-into-pool str)
    (make-strlike TSPECIAL start (- byte-free start))))

; A Mes TSTRING from an rsc string (D5/D8 helpers).
(define (string-rsc str)
  (let ((start byte-free))
    (copy-rsc-into-pool str)
    (make-strlike TSTRING start (- byte-free start))))
; %argv (mes.c:93-98 mes_environment): the real process argv (argv[0..]) as a
; Mes string list; (command-line) returns it verbatim (base.mes:75).  The rsc
; `command-line` primitive yields the host argv as rsc strings.
(define (mes-command-line) (mes-argv-loop (command-line)))
(define (mes-argv-loop lst)
  (if (null? lst) cell-nil
      (qcons (string-rsc (car lst)) (mes-argv-loop (cdr lst)))))
; Copy a Mes strlike's bytes out to a fresh rsc string (for getenv/open args).
(define (mes-string->rsc s)
  (let ((len (strlike-len s)) (off (strlike-offset s)))
    (m2r-loop (make-string len) off 0 len)))
(define (m2r-loop r off i n)
  (if (< i n)
      (begin (string-set! r i (string-ref g-bytes (+ off i))) (m2r-loop r off (+ i 1) n))
      r))

; ===========================================================================
; List helpers (core.c length__, assq)
; ===========================================================================
(define (length- x) (length-loop x 0))
(define (length-loop x n)
  (cond ((= x cell-nil) n)
        ((not (= (cell-type x) TPAIR)) -1)
        (else (length-loop (cell-cdr x) (+ n 1)))))

; assq (core.c:211-253): dispatch on the KEY type — TSYMBOL/TSPECIAL and the
; default use pointer (cell-index) equality; TCHAR/TNUMBER compare by value
; (each numeric literal is a distinct cell, so identity is wrong — this is what
; broke nyacc's LALR tables, whose action alists are keyed by integer token
; ids); TKEYWORD compares by string.  -> the (key . val) pair or cell-f.
(define (qassq x a)
  (if (not (= (cell-type a) TPAIR)) cell-f
      (let ((t (cell-type x)))
        (cond ((or (= t TCHAR) (= t TNUMBER)) (qassq-value x a))
              ((= t TKEYWORD) (qassq-keyword x a))
              (else (qassq-loop x a))))))
(define (qassq-loop x a)
  (cond ((= a cell-nil) cell-f)
        ((= (cell-car (cell-car a)) x) (cell-car a))
        (else (qassq-loop x (cell-cdr a)))))
(define (qassq-value x a)
  (cond ((= a cell-nil) cell-f)
        ((num=? x (cell-car (cell-car a))) (cell-car a))
        (else (qassq-value x (cell-cdr a)))))
(define (qassq-keyword x a)
  (cond ((= a cell-nil) cell-f)
        ((= (string-eq-p x (cell-car (cell-car a))) cell-t) (cell-car a))
        (else (qassq-keyword x (cell-cdr a)))))

; ===========================================================================
; Vectors / structs / TREF (vector.c, struct.c)
; ===========================================================================
(define (vector-entry x)
  (let ((ty (cell-type x)))
    (if (or (= ty TCHAR) (= ty TNUMBER)) x (make-ref x))))

(define (unwrap-entry e)                       ; ref/char/number unwrap on ref
  (let ((ty (cell-type e)))
    (cond ((= ty TREF) (cell-car e))
          ((= ty TCHAR) (make-char (char-value e)))
          ((= ty TNUMBER) (copy-num e))
          (else e))))

(define (make-vector- k e)
  (let ((x (alloc-n 1)) (v (alloc-n k)))
    (set-type! x TVECTOR)
    (set-car! x k)
    (set-cdr! x v)
    (vfill- v 0 k e)
    x))
(define (vfill- v i k e)
  (if (< i k)
      (begin (copy-cell! (+ v i) (vector-entry e)) (vfill- v (+ i 1) k e))
      'ok))
(define (vector-length- x) (cell-car x))
(define (vector-body x) (cell-cdr x))
(define (vector-ref- x i) (unwrap-entry (+ (vector-body x) i)))
(define (vector-set-x- x i e) (copy-cell! (+ (vector-body x) i) (vector-entry e)))
(define (list->vector- x)
  (let ((v (make-vector- (length- x) cell-unspec)))
    (l2v-loop v 0 x)
    v))
(define (l2v-loop v i x)
  (if (= x cell-nil) 'ok
      (begin (vector-set-x- v i (cell-car x)) (l2v-loop v (+ i 1) (cell-cdr x)))))

(define (make-struct type fields printer)
  (let* ((size (+ 2 (length- fields)))
         (x (alloc-n 1))
         (v (alloc-n size)))
    (set-type! x TSTRUCT)
    (set-car! x size)
    (set-cdr! x v)
    (copy-cell! v (vector-entry type))
    (copy-cell! (+ v 1) (vector-entry printer))
    (struct-fill! v 2 size fields)
    x))
(define (struct-fill! v i size fields)
  (if (< i size)
      (let ((e (if (= fields cell-nil) cell-unspec (cell-car fields))))
        (copy-cell! (+ v i) (vector-entry e))
        (struct-fill! v (+ i 1) size
                      (if (= fields cell-nil) fields (cell-cdr fields))))
      'ok))
(define (struct-body x) (cell-cdr x))
(define (struct-ref- x i) (unwrap-entry (+ (struct-body x) i)))
(define (struct-set-x- x i e) (copy-cell! (+ (struct-body x) i) (vector-entry e)))

; ===========================================================================
; Variables (variable.c) — D3.  make_variable_type = record-type struct with
; fields (<variable> (value)); make_variable = TSTRUCT of length 4:
; [variable-type, 'variable-printer, '<variable>, value].  variable? checks
; struct-ref 0 == variable-type.
; ===========================================================================
(define (make-variable-type)
  (if (= variable-type-struct 0)
      (set! variable-type-struct
            (make-struct cell-symbol-record-type
                         (qcons cell-symbol-variable
                                (qcons (qcons (intern-rsc "value") cell-nil) cell-nil))
                         cell-unspec))
      'ok)
  variable-type-struct)
(define (make-variable value)
  (make-struct (make-variable-type)
               (qcons cell-symbol-variable (qcons value cell-nil))
               variable-printer-sym))
(define (variable-ref var) (struct-ref- var 3))
(define (variable-set-x var val) (struct-set-x- var 3 val))
(define (variable-p x)
  (if (and (= (cell-type x) TSTRUCT) (= (struct-ref- x 0) (make-variable-type)))
      cell-t cell-f))

; ===========================================================================
; Hash tables (hash.c) — TSTRUCT: [type printer 'hashq-table size buckets]
; hashq uses the first two name bytes (hash_cstring parity).
; ===========================================================================
; make_hash_table_type (hash.c): record-type struct, fields
; (<hashq-table> (size buckets)); struct-ref 0 == this type for hash-table?.
(define (make-hash-table-type)
  (if (= hash-table-type-struct 0)
      (set! hash-table-type-struct
            (make-struct cell-symbol-record-type
                         (qcons cell-symbol-hashq-table
                                (qcons (qcons cell-symbol-size
                                              (qcons cell-symbol-buckets cell-nil))
                                       cell-nil))
                         cell-unspec))
      'ok)
  hash-table-type-struct)
(define (make-hash-table- size0)
  (let* ((size (if (= size0 0) 100 size0))
         (type (make-hash-table-type))
         (buckets (make-vector- size cell-unspec)))
    (make-struct type
                 (qcons cell-symbol-hashq-table
                        (qcons (make-number-fx size)
                               (qcons buckets cell-nil)))
                 cell-unspec)))
(define (hash-table-p x)
  (if (and (= (cell-type x) TSTRUCT) (= (struct-ref- x 0) (make-hash-table-type)))
      cell-t cell-f))
(define (hashq- key size)
  (let* ((off (strlike-offset key))
         (len (strlike-len key))
         (b0 (char->integer (string-ref g-bytes off)))
         (b1 (if (> len 1) (char->integer (string-ref g-bytes (+ off 1))) 0))
         (h (+ (* b0 37) (if (and (not (= b0 0)) (not (= b1 0))) (* b1 43) 0))))
    (remainder h size)))
(define (ht-size table) (num-fixnum (struct-ref- table 3)))
(define (ht-buckets table) (struct-ref- table 4))
(define (hashq-get-handle table key)
  (let* ((size (ht-size table))
         (h (hashq- key size))
         (buckets (ht-buckets table))
         (bucket (vector-ref- buckets h)))
    (if (= (cell-type bucket) TPAIR) (qassq key bucket) cell-f)))
(define (hashq-ref- table key dflt)
  (let ((x (hashq-get-handle table key)))
    (if (not (= x cell-f)) (cell-cdr x) dflt)))
(define (hashq-set-x table key value)
  (hash-set-x- table (hashq- key (ht-size table)) key value))
; hash_set_x_ (hash.c:115): prepend (key . value) at the bucket index.
(define (hash-set-x- table h key value)
  (let* ((buckets (ht-buckets table))
         (bucket0 (vector-ref- buckets h))
         (bucket (if (= (cell-type bucket0) TPAIR) bucket0 cell-nil)))
    (vector-set-x- buckets h (acons key value bucket))
    value))
; hash_ (hash.c:48): cstring hash for TSTRING keys, else 0.
(define (hash-str- key size)
  (if (= (cell-type key) TSTRING) (hashq- key size) 0))
; hash-set! (hash_set_x, hash.c:171): string-keyed set.
(define (hash-set-x table key value)
  (hash-set-x- table (hash-str- key (ht-size table)) key value))
; core:hash-ref (hash_ref_, hash.c:95): equal2-based assoc, cdr or dflt.
(define (hash-ref- table key dflt)
  (let* ((size (ht-size table))
         (h (hash-str- key size))
         (bucket (vector-ref- (ht-buckets table) h)))
    (if (= (cell-type bucket) TPAIR)
        (let ((x (assoc- key bucket))) (if (not (= x cell-f)) (cell-cdr x) dflt))
        dflt)))
; assoc (core.c:256): TSTRING keys use string_equal_p over string keys only;
; otherwise equal2-based association lookup.
(define (assoc- x a)
  (if (= (cell-type x) TSTRING) (assoc-string- x a) (assoc-eq- x a)))
(define (assoc-string- x a)
  (cond ((= a cell-nil) cell-f)
        ((and (= (cell-type (cell-car (cell-car a))) TSTRING)
              (= (string-eq-p x (cell-car (cell-car a))) cell-t)) (cell-car a))
        (else (assoc-string- x (cell-cdr a)))))
(define (assoc-eq- x a)
  (cond ((not (= (cell-type a) TPAIR)) cell-f)
        ((= (equal2- x (cell-car (cell-car a))) cell-t) (cell-car a))
        (else (assoc-eq- x (cell-cdr a)))))
; create_handle_x (hash.c:136): find-or-create (key . init) handle at index.
(define (create-handle-x table key index init)
  (let* ((buckets (ht-buckets table))
         (bucket0 (vector-ref- buckets index))
         (bucket (if (= (cell-type bucket0) TPAIR) bucket0 cell-nil))
         (handle (qassq key bucket)))
    (if (= handle cell-f)
        (let ((h (qcons key init)))
          (vector-set-x- buckets index (qcons h bucket))
          h)
        handle)))
(define (hashq-create-handle-x table key init)
  (create-handle-x table key (hashq- key (ht-size table)) init))
(define (hash-create-handle-x table key init)
  (create-handle-x table key (hash-str- key (ht-size table)) init))
; hash-clear! (hash_clear_x, hash.c:303): replace buckets with a fresh vector.
(define (hash-clear-x table)
  (struct-set-x- table 4 (make-vector- (ht-size table) cell-unspec))
  cell-unspec)
; hash-remove! (hash_remove_x, hash.c:180): drop matching entries from bucket.
(define (hash-remove-x table key)
  (let* ((h (hash-str- key (ht-size table)))
         (buckets (ht-buckets table))
         (bucket (hr-skip-head key (vector-ref- buckets h))))
    (if (not (= bucket cell-nil)) (hr-scan key bucket (cell-cdr bucket)) 'ok)
    (vector-set-x- buckets h bucket)
    cell-unspec))
(define (hr-skip-head key bucket)
  (if (and (not (= bucket cell-nil))
           (= (equal2- key (cell-car (cell-car bucket))) cell-t))
      (hr-skip-head key (cell-cdr bucket))
      bucket))
(define (hr-scan key p b)
  (if (= b cell-nil) 'ok
      (if (= (equal2- key (cell-car (cell-car b))) cell-t)
          (begin (set-cdr! p (cell-cdr b)) (hr-scan key p (cell-cdr b)))
          (hr-scan key b (cell-cdr b)))))

; ===========================================================================
; Modules (module.c) — M1 = cell-f path (module system unbooted)
; ===========================================================================
(define (make-initial-module a)
  (let ((m (make-hash-table- 100)))
    (mim-loop m a)
    m))
(define (mim-loop m a)
  (if (= (cell-type a) TPAIR)
      (let ((entry (cell-car a)))
        (hashq-set-x m (cell-car entry) (make-variable (cell-cdr entry)))
        (mim-loop m (cell-cdr a)))
      'ok))
; set_current_module (module.c:51): swap M1, return the previous module.
(define (b-set-current-module module)
  (let ((previous m1)) (set! m1 module) previous))
; current_module_variable (module.c:59): unbooted -> M0 hashq path; booted ->
; the current module's eval-closure (standard fast paths, or apply a closure).
(define (current-module-variable name define-p)
  (if (= m1 cell-f)
      (let ((var (hashq-ref- m0 name cell-f)))
        (if (and (= var cell-f) (not (= define-p cell-f)))
            (hashq-set-x m0 name (make-variable cell-undefined))
            var))
      (let ((eval-closure (struct-ref- m1 6)))         ; MODULE_EVAL_CLOSURE
        (cond
          ((= eval-closure cell-symbol-standard-eval-closure)
           (standard-eval-closure- name define-p))
          ((= eval-closure cell-symbol-standard-interface-eval-closure)
           (standard-interface-eval-closure- name define-p))
          (else (apply-proc eval-closure
                            (qcons name (qcons define-p cell-nil)) cell-nil))))))
(define (standard-eval-closure- name define-p)
  (if (not (= define-p cell-f))
      (module-make-local-var-x m1 name)
      (module-variable- m1 name)))
(define (standard-interface-eval-closure- name define-p)
  (if (not (= define-p cell-f)) cell-f (module-variable- m1 name)))
; module_make_local_var_x (module.c:117): intern name in the module's obarray.
(define (module-make-local-var-x module name)
  (let* ((obarray (struct-ref- module 3))            ; MODULE_OBARRAY
         (handle (hashq-create-handle-x obarray name (make-variable cell-undefined))))
    (cell-cdr handle)))
; module_variable (module.c:132): search module then its uses transitively.
(define (module-variable- module name)
  (mv-loop name (qcons module cell-nil)))
(define (mv-loop name modules)
  (if (not (= (cell-type modules) TPAIR)) cell-f
      (let* ((module (cell-car modules))
             (obarray (struct-ref- module 3))
             (variable (hashq-ref- obarray name cell-f)))
        (if (not (= variable cell-f)) variable
            (mv-loop name (append2 (struct-ref- module 4)   ; MODULE_USES
                                   (cell-cdr modules)))))))

; Recursive-evaluator global lookup, now through M0 (E2).
(define (global-lookup sym)
  (let ((var (current-module-variable sym cell-f)))
    (if (= var cell-f) (begin (qerror-diag "global-lookup" sym) (qfail)) (variable-ref var))))

; D1: a builtin is a TSTRUCT per builtins.c:29-64.
;   make_builtin_type = record-type struct, fields (<builtin> (name arity address))
;   a builtin instance = [builtin-type, 'builtin-printer, '<builtin>,
;                         name-string, arity-number, id-number]
; so struct-ref 2 = '<builtin> (builtin? test), 3 = name, 4 = arity, 5 = id.
(define (make-builtin-type)
  (if (= builtin-type-struct 0)
      (set! builtin-type-struct
            (make-struct cell-symbol-record-type
                         (qcons cell-symbol-builtin
                                (qcons (qcons (intern-rsc "name")
                                              (qcons (intern-rsc "arity")
                                                     (qcons (intern-rsc "address") cell-nil)))
                                       cell-nil))
                         cell-unspec))
      'ok)
  builtin-type-struct)
(define (make-builtin name-str arity id)
  (make-struct (make-builtin-type)
               (qcons cell-symbol-builtin
                      (qcons name-str
                             (qcons (make-number-fx arity)
                                    (qcons (make-number-fx id) cell-nil))))
               builtin-printer-sym))
(define (builtin-p x)
  (if (and (= (cell-type x) TSTRUCT) (= (struct-ref- x 2) cell-symbol-builtin))
      cell-t cell-f))
(define (builtin-name- b) (struct-ref- b 3))
(define (builtin-arity- b) (struct-ref- b 4))
(define (builtin-id b) (num-fixnum (struct-ref- b 5)))
(define (bind-builtin name id arity)
  (let ((sym (intern-rsc name)))
    (set! env-alist (acons sym (make-builtin (retag TSTRING sym) arity id) env-alist))))

(define (qfail)
  (if (= qmes-debug-err 0) 'ok (emit-str g-stderr ";;; qmes-qfail\n"))
  (exit 1))    ; unreachable on the milestone forms

; Builtin ids
(define ID-CONS 1)
(define ID-CAR 2)
(define ID-CDR 3)
(define ID-LIST 4)
(define ID-EXIT 5)
(define ID-NULLP 6)
(define ID-PAIRP 7)
(define ID-EQP 8)
(define ID-DISPLAY 9)
(define ID-WRITE 10)
(define ID-DISPLAY-ERR 11)
(define ID-WRITE-ERR 12)
(define ID-SETCAR 13)
(define ID-SETCDR 14)
(define ID-CURRENT-MODULE 15)
(define ID-LENGTH 16)
(define ID-MEMQ 17)
(define ID-EQUAL2 18)
(define ID-STRINGEQ 19)
(define ID-STRING-APPEND 20)
(define ID-PLUS 22)
(define ID-MINUS 23)
(define ID-IS 26)              ; =
(define ID-CORE-TYPE 35)
(define ID-APPEND2 36)
(define ID-VECTOR-LIST 38)    ; vector->list
(define ID-STRING-LIST 39)    ; string->list
(define ID-LIST-STRING 40)    ; list->string
(define ID-SYM-KEYWORD 43)    ; symbol->keyword
(define ID-KEYWORD-STRING 44) ; keyword->string
; ports (posix.c)
(define ID-OPEN-INPUT-STRING 50)
(define ID-CURRENT-INPUT-PORT 51)
(define ID-SET-CURRENT-INPUT-PORT 52)
(define ID-READ-STRING 53)
(define ID-CURRENT-OUTPUT-PORT 56)
(define ID-WRITE-CHAR 58)
(define ID-DISPLAY-PORT 59)
(define ID-WRITE-PORT 60)
; D8 tranche B0-B2
(define ID-CORE-HASHQ-REF 61)
(define ID-INITIAL-MODULE 62)
(define ID-CORE-REVERSE 63)
(define ID-APPEND-REVERSE 64)
(define ID-GETENV 65)
(define ID-CHAR-INT 66)
(define ID-INT-CHAR 67)
(define ID-STRING-SYMBOL 68)
(define ID-SYMBOL-STRING 69)
(define ID-CORE-CAR 70)
(define ID-CORE-CDR 71)
(define ID-ACONS 72)
(define ID-ASSQ 73)
(define ID-BUILTINP 74)
(define ID-BUILTIN-NAME 75)
(define ID-BUILTIN-ARITY 76)
(define ID-BUILTIN-PRINTER 77)
(define ID-MAKE-VARIABLE 78)
(define ID-VARIABLEP 79)
(define ID-VARIABLE-REF 80)
(define ID-VARIABLE-SET 81)
(define ID-HASHQ-GET-HANDLE 82)
(define ID-HASHQ-SET 83)
(define ID-MAKE-HASH-TABLE 84)
(define ID-HASH-TABLEP 85)
(define ID-MAKE-STRUCT 86)
(define ID-STRUCT-LENGTH 87)
(define ID-STRUCT-REF 88)
(define ID-STRUCT-SET 89)
(define ID-LIST-VECTOR 90)
(define ID-VECTORP 91)
(define ID-VECTOR-LENGTH 92)
(define ID-VECTOR-REF 93)
(define ID-VECTOR-SET 94)
(define ID-MAKE-VECTOR 95)
(define ID-CURRENT-ERROR-PORT 96)
(define ID-LAST-PAIR 97)
(define ID-MAKE-SYMBOL 98)
(define ID-PRIMITIVE-LOAD 99)
(define ID-OPEN-INPUT-FILE 100)
(define ID-READ-CHAR 101)
(define ID-PEEK-CHAR 102)
(define ID-READ-INPUT-FILE-ENV 103)
(define ID-GC 104)              ; S2: gc / gc-stats / gc-check builtins
(define ID-GC-STATS 105)
(define ID-GC-CHECK 106)
(define ID-VALUES 107)          ; S3: values / stack.c (§3)
(define ID-MAKE-STACK 108)
(define ID-STACK-LENGTH 109)
(define ID-STACK-REF 110)
(define ID-MULT 111)            ; S4/B4: math.c arithmetic tranche
(define ID-DIV 112)
(define ID-LESS 113)
(define ID-GREATER 114)
(define ID-MODULO 115)
(define ID-ASH 118)
(define ID-LOGAND 119)
(define ID-LOGIOR 120)
(define ID-LOGXOR 121)
(define ID-LOGNOT 122)
(define ID-ERROR 123)           ; B4: core.c error -> throw
(define ID-STRING-LENGTH 124)   ; B8: string.c
(define ID-STRING-REF 125)
(define ID-STRING-SET 126)
(define ID-ACCESS 127)          ; B8: posix.c access?
(define ID-ISATTY 128)          ; B8: posix.c isatty?
(define ID-WRITE-BYTE 129)      ; B8: posix.c write-byte
(define ID-READ-BYTE 130)
(define ID-PEEK-BYTE 131)
(define ID-UNREAD-BYTE 132)
(define ID-HASH-SET 133)        ; B11: hash.c string-keyed hash tranche
(define ID-CORE-HASH-REF 134)
(define ID-HASH-REMOVE 135)
(define ID-HASH-CLEAR 136)
(define ID-HASH-BUCKETS 137)
(define ID-HASH-CREATE-HANDLE 138)
(define ID-HASHQ-CREATE-HANDLE 139)
(define ID-SET-CURRENT-MODULE 140)
(define ID-MAKE-BINDING 141)    ; B12: eval-apply.c make-binding
(define ID-ASSOC 142)           ; B12: core.c assoc
(define ID-OPEN-OUTPUT-FILE 143)       ; S5: posix.c open-output-file (MesCC -o)
(define ID-SET-CURRENT-OUTPUT-PORT 144) ; S5: posix.c set-current-output-port

; ===========================================================================
; Initialisation
; ===========================================================================
(define (init-cells)
  (set! cell-nil (special-rsc "()"))
  (set! cell-f (special-rsc "#f"))
  (set! cell-t (special-rsc "#t"))
  (set! cell-dot (special-rsc "."))
  (set! cell-arrow (special-rsc "=>"))
  (set! cell-undefined (special-rsc "*undefined*"))
  (set! cell-unspec (special-rsc "*unspecified*"))
  (set! cell-closure (special-rsc "*closure*"))
  (set! cell-circular (special-rsc "*circular*"))
  (set! cell-eof (special-rsc "*eof*"))

  (set! cell-vm-apply (special-rsc "core:apply"))
  (set! cell-vm-apply2 (special-rsc "*vm-apply2*"))
  (set! cell-vm-begin (special-rsc "*vm-begin*"))
  (set! cell-vm-begin-eval (special-rsc "*vm:begin-eval*"))
  (set! cell-vm-begin-expand (special-rsc "core:eval"))
  (set! cell-vm-begin-expand-eval (special-rsc "*vm:begin-expand-eval*"))
  (set! cell-vm-begin-expand-macro (special-rsc "*vm:begin-expand-macro*"))
  (set! cell-vm-call-with-current-continuation2 (special-rsc "*vm-cc2*"))
  (set! cell-vm-call-with-values2 (special-rsc "*vm-cwv2*"))
  (set! cell-vm-eval (special-rsc "core:eval-expanded"))
  (set! cell-vm-eval2 (special-rsc "*vm-eval2*"))
  (set! cell-vm-eval-check-func (special-rsc "*vm-eval-check-func*"))
  (set! cell-vm-eval-define (special-rsc "*vm-eval-define*"))
  (set! cell-vm-eval-macro-expand-eval (special-rsc "*vm:eval-macro-expand-eval*"))
  (set! cell-vm-eval-macro-expand-expand (special-rsc "*vm:eval-macro-expand-expand*"))
  (set! cell-vm-eval-set-x (special-rsc "*vm-eval-set!*"))
  (set! cell-vm-evlis (special-rsc "*vm-evlis*"))
  (set! cell-vm-evlis2 (special-rsc "*vm-evlis2*"))
  (set! cell-vm-evlis3 (special-rsc "*vm-evlis3*"))
  (set! cell-vm-if (special-rsc "*vm-if*"))
  (set! cell-vm-if-expr (special-rsc "*vm-if-expr*"))
  (set! cell-vm-macro-expand (special-rsc "core:macro-expand"))
  (set! cell-vm-macro-expand-car (special-rsc "*vm:core:macro-expand-car*"))
  (set! cell-vm-macro-expand-cdr (special-rsc "*vm:macro-expand-cdr*"))
  (set! cell-vm-macro-expand-define (special-rsc "*vm:core:macro-expand-define*"))
  (set! cell-vm-macro-expand-define-macro (special-rsc "*vm:core:macro-expand-define-macro*"))
  (set! cell-vm-macro-expand-lambda (special-rsc "*vm:core:macro-expand-lambda*"))
  (set! cell-vm-macro-expand-set-x (special-rsc "*vm:core:macro-expand-set!*"))
  (set! cell-vm-return (special-rsc "*vm-return*"))

  (set! sym-table cell-nil)
  (set! env-alist cell-nil)

  (set! cell-symbol-lambda (intern-rsc "lambda"))
  (set! cell-symbol-begin (intern-rsc "begin"))
  (set! cell-symbol-if (intern-rsc "if"))
  (set! cell-symbol-quote (intern-rsc "quote"))
  (set! cell-symbol-define (intern-rsc "define"))
  (set! cell-symbol-define-macro (intern-rsc "define-macro"))
  (set! cell-symbol-set-x (intern-rsc "set!"))
  (set! cell-symbol-quasiquote (intern-rsc "quasiquote"))
  (set! cell-symbol-unquote (intern-rsc "unquote"))
  (set! cell-symbol-unquote-splicing (intern-rsc "unquote-splicing"))
  (set! cell-symbol-call-with-values (intern-rsc "call-with-values"))
  (set! cell-symbol-call-with-current-continuation (intern-rsc "call-with-current-continuation"))
  (set! cell-symbol-current-environment (intern-rsc "current-environment"))
  (set! cell-symbol-car (intern-rsc "car"))
  (set! cell-symbol-cdr (intern-rsc "cdr"))
  (set! cell-symbol-not-a-pair (intern-rsc "not-a-pair"))
  (set! cell-symbol-system-error (intern-rsc "system-error"))
  (set! cell-symbol-throw (intern-rsc "throw"))
  (set! cell-symbol-unbound-variable (intern-rsc "unbound-variable"))
  (set! cell-symbol-wrong-number-of-args (intern-rsc "wrong-number-of-args"))
  (set! cell-symbol-wrong-type-arg (intern-rsc "wrong-type-arg"))
  (set! cell-symbol-record-type (intern-rsc "<record-type>"))
  (set! cell-symbol-standard-eval-closure (intern-rsc "standard-eval-closure"))
  (set! cell-symbol-standard-interface-eval-closure
        (intern-rsc "standard-interface-eval-closure"))
  (set! cell-symbol-hashq-table (intern-rsc "<hashq-table>"))
  (set! cell-symbol-variable (intern-rsc "<variable>"))
  (set! cell-symbol-builtin (intern-rsc "<builtin>"))
  (set! cell-symbol-buckets (intern-rsc "buckets"))
  (set! cell-symbol-size (intern-rsc "size"))
  (set! builtin-printer-sym (intern-rsc "builtin-printer"))
  (set! variable-printer-sym (intern-rsc "variable-printer"))
  (set! cell-symbol-procedure (intern-rsc "procedure"))
  (set! cell-symbol-frame (intern-rsc "frame"))
  (set! cell-symbol-stack (intern-rsc "stack"))
  (set! cell-symbol-frames (intern-rsc "frames"))
  (set! frame-printer-sym (intern-rsc "frame-printer"))
  (set! builtin-type-struct 0)
  (set! variable-type-struct 0)
  (set! hash-table-type-struct 0)
  (set! cell-symbol-program (intern-rsc "%program"))
  (set! cell-symbol-portable-macro-expand (intern-rsc "portable-macro-expand"))
  (set! cell-symbol-sc-expander-alist (intern-rsc "*sc-expander-alist*"))
  (set! cell-symbol-macro-expand (intern-rsc "macro-expand"))

  ; Mes registers the fixed TSPECIAL cells in g_symbols too, so the reader
  ; resolves their names to the special cell (not a fresh symbol).  Register
  ; the ones that appear as identifiers in Scheme source (core:apply etc.).
  (set! sym-table (qcons cell-vm-apply sym-table))
  (set! sym-table (qcons cell-vm-eval sym-table))
  (set! sym-table (qcons cell-vm-begin-expand sym-table))
  (set! sym-table (qcons cell-vm-macro-expand sym-table))
  ; *unspecified*/*undefined* appear as literals (e.g. 4f's named-let macro);
  ; they must self-evaluate to the special cell, not intern as fresh symbols.
  (set! sym-table (qcons cell-unspec sym-table))
  (set! sym-table (qcons cell-undefined sym-table)))

(define (bind-value name val) (set! env-alist (acons name val env-alist)))
(define (bind-type str tnum) (bind-value (intern-rsc str) (make-number-fx tnum)))

(define (init-builtins)
  ; type-number bindings (<cell:*>) — 20-define-quote reads <cell:char>
  (bind-type "<cell:bytes>" TBYTES)
  (bind-type "<cell:char>" TCHAR)
  (bind-type "<cell:closure>" TCLOSURE)
  (bind-type "<cell:continuation>" TCONTINUATION)
  (bind-type "<cell:keyword>" TKEYWORD)
  (bind-type "<cell:macro>" TMACRO)
  (bind-type "<cell:number>" TNUMBER)
  (bind-type "<cell:pair>" TPAIR)
  (bind-type "<cell:port>" TPORT)
  (bind-type "<cell:ref>" TREF)
  (bind-type "<cell:special>" TSPECIAL)
  (bind-type "<cell:string>" TSTRING)
  (bind-type "<cell:struct>" TSTRUCT)
  (bind-type "<cell:symbol>" TSYMBOL)
  (bind-type "<cell:values>" TVALUES)
  (bind-type "<cell:binding>" TBINDING)
  (bind-type "<cell:vector>" TVECTOR)
  (bind-type "<cell:broken-heart>" TBROKEN-HEART)
  ; self-bound specials (mes_environment)
  (bind-value cell-symbol-call-with-current-continuation cell-symbol-call-with-current-continuation)
  (bind-value cell-symbol-call-with-values cell-symbol-call-with-values)
  (bind-value cell-symbol-current-environment cell-symbol-current-environment)
  (bind-value cell-symbol-lambda cell-symbol-lambda)
  (bind-value cell-symbol-quote cell-symbol-quote)
  (bind-value cell-symbol-begin cell-symbol-begin)
  (bind-value cell-symbol-if cell-symbol-if)
  (bind-value cell-symbol-set-x cell-symbol-set-x)
  (bind-value cell-symbol-define cell-symbol-define)
  (bind-value cell-symbol-define-macro cell-symbol-define-macro)
  ; builtins (mes_builtins subset)
  (bind-builtin "cons" ID-CONS 2)
  (bind-builtin "car" ID-CAR 1)
  (bind-builtin "cdr" ID-CDR 1)
  (bind-builtin "list" ID-LIST -1)
  (bind-builtin "null?" ID-NULLP 1)
  (bind-builtin "pair?" ID-PAIRP 1)
  (bind-builtin "eq?" ID-EQP 2)
  (bind-builtin "core:display" ID-DISPLAY 1)
  (bind-builtin "core:write" ID-WRITE 1)
  (bind-builtin "core:display-error" ID-DISPLAY-ERR 1)
  (bind-builtin "core:write-error" ID-WRITE-ERR 1)
  (bind-builtin "set-car!" ID-SETCAR 2)
  (bind-builtin "set-cdr!" ID-SETCDR 2)
  (bind-builtin "current-module" ID-CURRENT-MODULE 0)
  (bind-builtin "length" ID-LENGTH 1)
  (bind-builtin "memq" ID-MEMQ 2)
  (bind-builtin "equal2?" ID-EQUAL2 2)
  (bind-builtin "string=?" ID-STRINGEQ 2)
  (bind-builtin "string-append" ID-STRING-APPEND -1)
  (bind-builtin "string-length" ID-STRING-LENGTH 1)
  (bind-builtin "string-ref" ID-STRING-REF 2)
  (bind-builtin "string-set!" ID-STRING-SET 3)
  ; math.c
  (bind-builtin "+" ID-PLUS -1)
  (bind-builtin "-" ID-MINUS -1)
  (bind-builtin "=" ID-IS -1)
  (bind-builtin "*" ID-MULT -1)
  (bind-builtin "/" ID-DIV -1)
  (bind-builtin "<" ID-LESS -1)
  (bind-builtin ">" ID-GREATER -1)
  (bind-builtin "modulo" ID-MODULO 2)
  (bind-builtin "ash" ID-ASH 2)
  (bind-builtin "logand" ID-LOGAND -1)
  (bind-builtin "logior" ID-LOGIOR -1)
  (bind-builtin "logxor" ID-LOGXOR -1)
  (bind-builtin "lognot" ID-LOGNOT 1)
  (bind-builtin "error" ID-ERROR 2)
  ; lib.c
  (bind-builtin "core:type" ID-CORE-TYPE 1)
  (bind-builtin "append2" ID-APPEND2 2)
  ; vector.c
  (bind-builtin "vector->list" ID-VECTOR-LIST 1)
  ; string.c
  (bind-builtin "string->list" ID-STRING-LIST 1)
  (bind-builtin "list->string" ID-LIST-STRING 1)
  (bind-builtin "symbol->keyword" ID-SYM-KEYWORD 1)
  (bind-builtin "keyword->string" ID-KEYWORD-STRING 1)
  ; posix.c ports
  (bind-builtin "open-input-string" ID-OPEN-INPUT-STRING 1)
  (bind-builtin "current-input-port" ID-CURRENT-INPUT-PORT 0)
  (bind-builtin "set-current-input-port" ID-SET-CURRENT-INPUT-PORT 1)
  (bind-builtin "read-string" ID-READ-STRING -1)
  (bind-builtin "current-output-port" ID-CURRENT-OUTPUT-PORT 0)
  (bind-builtin "set-current-output-port" ID-SET-CURRENT-OUTPUT-PORT 1)
  (bind-builtin "open-output-file" ID-OPEN-OUTPUT-FILE 1)
  (bind-builtin "write-char" ID-WRITE-CHAR -1)
  (bind-builtin "write-byte" ID-WRITE-BYTE -1)
  (bind-builtin "read-byte" ID-READ-BYTE 0)
  (bind-builtin "peek-byte" ID-PEEK-BYTE 0)
  (bind-builtin "unread-byte" ID-UNREAD-BYTE 1)
  (bind-builtin "core:display-port" ID-DISPLAY-PORT 2)
  (bind-builtin "core:write-port" ID-WRITE-PORT 2)
  (bind-builtin "exit" ID-EXIT 1)
  ; D8 tranche B0-B2 (builtins.c names/arities)
  (bind-builtin "core:hashq-ref" ID-CORE-HASHQ-REF 3)
  (bind-builtin "hashq-get-handle" ID-HASHQ-GET-HANDLE 2)
  (bind-builtin "hashq-set!" ID-HASHQ-SET 3)
  (bind-builtin "make-hash-table" ID-MAKE-HASH-TABLE -1)
  (bind-builtin "hash-table?" ID-HASH-TABLEP 1)
  (bind-builtin "hash-set!" ID-HASH-SET 3)
  (bind-builtin "core:hash-ref" ID-CORE-HASH-REF 3)
  (bind-builtin "hash-remove!" ID-HASH-REMOVE 2)
  (bind-builtin "hash-clear!" ID-HASH-CLEAR 1)
  (bind-builtin "hash-buckets" ID-HASH-BUCKETS 1)
  (bind-builtin "hash-create-handle!" ID-HASH-CREATE-HANDLE 3)
  (bind-builtin "hashq-create-handle!" ID-HASHQ-CREATE-HANDLE 3)
  (bind-builtin "set-current-module" ID-SET-CURRENT-MODULE 1)
  (bind-builtin "make-binding" ID-MAKE-BINDING 2)
  (bind-builtin "initial-module" ID-INITIAL-MODULE 0)
  (bind-builtin "core:reverse!" ID-CORE-REVERSE 2)
  (bind-builtin "append-reverse" ID-APPEND-REVERSE 2)
  (bind-builtin "getenv" ID-GETENV 1)
  (bind-builtin "char->integer" ID-CHAR-INT 1)
  (bind-builtin "integer->char" ID-INT-CHAR 1)
  (bind-builtin "string->symbol" ID-STRING-SYMBOL 1)
  (bind-builtin "symbol->string" ID-SYMBOL-STRING 1)
  (bind-builtin "make-symbol" ID-MAKE-SYMBOL 1)
  (bind-builtin "core:car" ID-CORE-CAR 1)
  (bind-builtin "core:cdr" ID-CORE-CDR 1)
  (bind-builtin "acons" ID-ACONS 3)
  (bind-builtin "assq" ID-ASSQ 2)
  (bind-builtin "assoc" ID-ASSOC 2)
  (bind-builtin "last-pair" ID-LAST-PAIR 1)
  (bind-builtin "builtin?" ID-BUILTINP 1)
  (bind-builtin "builtin-name" ID-BUILTIN-NAME 1)
  (bind-builtin "builtin-arity" ID-BUILTIN-ARITY 1)
  (bind-builtin "builtin-printer" ID-BUILTIN-PRINTER 1)
  (bind-builtin "make-variable" ID-MAKE-VARIABLE 1)
  (bind-builtin "variable?" ID-VARIABLEP 1)
  (bind-builtin "variable-ref" ID-VARIABLE-REF 1)
  (bind-builtin "variable-set!" ID-VARIABLE-SET 2)
  (bind-builtin "make-struct" ID-MAKE-STRUCT 3)
  (bind-builtin "struct-length" ID-STRUCT-LENGTH 1)
  (bind-builtin "struct-ref" ID-STRUCT-REF 2)
  (bind-builtin "struct-set!" ID-STRUCT-SET 3)
  (bind-builtin "list->vector" ID-LIST-VECTOR 1)
  (bind-builtin "vector?" ID-VECTORP 1)
  (bind-builtin "vector-length" ID-VECTOR-LENGTH 1)
  (bind-builtin "vector-ref" ID-VECTOR-REF 2)
  (bind-builtin "vector-set!" ID-VECTOR-SET 3)
  (bind-builtin "make-vector" ID-MAKE-VECTOR -1)
  (bind-builtin "current-error-port" ID-CURRENT-ERROR-PORT 0)
  ; D7: primitive-load + port reader
  (bind-builtin "primitive-load" ID-PRIMITIVE-LOAD 1)
  (bind-builtin "open-input-file" ID-OPEN-INPUT-FILE 1)
  (bind-builtin "access?" ID-ACCESS 2)
  (bind-builtin "isatty?" ID-ISATTY 1)
  (bind-builtin "read-char" ID-READ-CHAR -1)
  (bind-builtin "peek-char" ID-PEEK-CHAR 0)
  (bind-builtin "read-input-file-env" ID-READ-INPUT-FILE-ENV 1)
  ; S2: garbage collector (gc.c / builtins.c:176-179)
  (bind-builtin "gc" ID-GC 0)
  (bind-builtin "gc-stats" ID-GC-STATS 0)
  (bind-builtin "gc-check" ID-GC-CHECK 0)
  ; S3: values + stack introspection (core.c / stack.c; builtins.c:151,287-289)
  (bind-builtin "values" ID-VALUES -1)
  (bind-builtin "make-stack" ID-MAKE-STACK -1)
  (bind-builtin "stack-length" ID-STACK-LENGTH 1)
  (bind-builtin "stack-ref" ID-STACK-REF 2)
  ; D5: config/env bindings (init_symbols + mes_environment)
  (bind-value (intern-rsc "%version") (string-rsc "0.27.1"))
  (bind-value (intern-rsc "%datadir") (string-rsc g-datadir))
  (bind-value (intern-rsc "%compiler") (string-rsc "gnuc"))
  (bind-value (intern-rsc "%arch") (string-rsc "x86"))
  (bind-value (intern-rsc "%argv") (mes-command-line))
  (bind-value (intern-rsc "hash-table-type") (make-hash-table-type))
  ; the (*closure* . a) head entry (symbol.c:205)
  (set! env-alist (acons cell-closure env-alist env-alist)))

; ===========================================================================
; Reader (src/reader.c) — port-based: readchar/peekchar/unreadchar over the
; current input port (D7).  A single-char pushback (rd-pb) implements
; unreadchar/peekchar; every input port is a string port (files are slurped
; into the byte pool), so the reader is uniform.  read_input_file_env stops on
; cell-nil (a top-level EOF or `)`), matching reader.c.
; ===========================================================================
(define rd-pb -2)                              ; pushback char, -2 = empty

; string-port-getc: read one byte from the current input string port, shrinking
; its string cell (posix.c readchar); -1 at EOF.
(define (string-port-getc)
  (let* ((port (find-port g-ports)))
    (if (= port cell-f) -1
        (let* ((s (cell-cdr port)) (len (strlike-len s)))
          (if (= len 0) -1
              (let ((c (char->integer (string-ref g-bytes (strlike-offset s)))))
                (set-cdr! port (make-strlike TSTRING (+ (strlike-offset s) 1) (- len 1)))
                c))))))
(define (getchar-)
  (if (= rd-pb -2) (string-port-getc)
      (let ((c rd-pb)) (set! rd-pb -2) c)))
(define (peekchar)
  (if (= rd-pb -2) (set! rd-pb (string-port-getc)) 'ok)
  rd-pb)
(define (unreadchar c) (if (< c 0) 'ok (set! rd-pb c)))

(define (whitespace? c)
  (or (= c 32) (= c 9) (= c 10) (= c 13) (= c 12) (= c 11)))
(define (digit? c) (and (>= c 48) (<= c 57)))
; reader_identifier_p: c > ' ' && c <= '~' && not "();  (reader.c:57)
(define (identifier-char? c)
  (and (> c 32) (<= c 126)
       (not (= c 34)) (not (= c 59)) (not (= c 40)) (not (= c 41))))
; reader_end_of_word_p (reader.c:63)
(define (end-of-word? c)
  (or (= c 34) (= c 59) (= c 40) (= c 41) (whitespace? c) (< c 0)))

(define (read-line-comment)                    ; consume to '\n'; return next char
  (let ((c (getchar-)))
    (cond ((< c 0) -1) ((= c 10) (getchar-)) (else (read-line-comment)))))
(define (reader-read-block-comment s c)        ; s=prev, c=cur; stop at |# or !#
  (cond ((< c 0) 'done)
        ((and (or (= s 124) (= s 33)) (= c 35)) 'done)
        (else (reader-read-block-comment c (getchar-)))))

; reader_read_sexp_ (reader.c:110): dispatch on the already-read char c.
(define (reader-read-sexp c)
  (cond
    ((< c 0) cell-nil)
    ((= c 59) (reader-read-sexp (read-line-comment)))
    ((whitespace? c) (reader-read-sexp (getchar-)))
    ((= c 40) (reader-read-list (getchar-)))
    ((= c 41) cell-nil)
    ((= c 35) (reader-read-hash (getchar-)))
    ((= c 96) (qcons cell-symbol-quasiquote (qcons (reader-read-sexp (getchar-)) cell-nil)))
    ((= c 44) (reader-read-unquote))
    ((= c 39) (qcons cell-symbol-quote (qcons (reader-read-sexp (getchar-)) cell-nil)))
    ((= c 34) (reader-read-string))
    ((= c 46) (if (identifier-char? (peekchar)) (reader-read-ident-or-number c) cell-dot))
    (else (reader-read-ident-or-number c))))
(define (reader-read-unquote)
  (if (= (peekchar) 64)                         ; ,@
      (begin (getchar-) (qcons cell-symbol-unquote-splicing (qcons (reader-read-sexp (getchar-)) cell-nil)))
      (qcons cell-symbol-unquote (qcons (reader-read-sexp (getchar-)) cell-nil))))

(define (reader-eat-whitespace c)
  (cond ((whitespace? c) (reader-eat-whitespace (getchar-)))
        ((= c 59) (reader-eat-whitespace (read-line-comment)))
        ((= c 35)
         (let ((p (peekchar)))
           (if (or (= p 33) (= p 124))
               (begin (getchar-) (reader-read-block-comment 35 (getchar-)) (reader-eat-whitespace (getchar-)))
               c)))
        (else c)))
(define (reader-read-list c)
  (let ((c (reader-eat-whitespace c)))
    (cond
      ((= c 41) cell-nil)
      ((< c 0) (qfail))                          ; EOF in list
      (else
       (let ((s (reader-read-sexp c)))
         (if (= s cell-dot)
             (cell-car (reader-read-list (getchar-)))
             (qcons s (reader-read-list (getchar-)))))))))

; token: store all chars until end-of-word (delimiter unread), then classify
; as number (numeric-token?) or symbol (reader.c:74-116 result).
(define (read-token-loop c)
  (if (end-of-word? c)
      (unreadchar c)
      (begin (bytes-put! (integer->char c)) (read-token-loop (getchar-)))))
(define (reader-read-ident-or-number c0)
  (let ((start byte-free))
    (read-token-loop c0)
    (let ((len (- byte-free start)))
      (if (numeric-token? start len)
          (let ((v (parse-number start len))) (set! byte-free start) v)
          (intern start len)))))
(define (numeric-token? start len)
  (if (= len 0) #f
      (let ((c0 (char->integer (string-ref g-bytes start))))
        (cond ((digit? c0) (all-digits? (+ start 1) (- len 1)))
              ((and (or (= c0 43) (= c0 45)) (> len 1))
               (all-digits? (+ start 1) (- len 1)))
              (else #f)))))
(define (all-digits? start len)
  (if (= len 0) #t
      (if (digit? (char->integer (string-ref g-bytes start)))
          (all-digits? (+ start 1) (- len 1)) #f)))
(define (parse-number start len)
  (let ((c0 (char->integer (string-ref g-bytes start))))
    (cond ((= c0 45)
           (make-number-w (w32-sub (w32-from-fixnum 0)
                                   (parse-digits (+ start 1) (- len 1) (w32-from-fixnum 0)))))
          ((= c0 43)
           (make-number-w (parse-digits (+ start 1) (- len 1) (w32-from-fixnum 0))))
          (else (make-number-w (parse-digits start len (w32-from-fixnum 0)))))))
(define (parse-digits start len acc)
  (if (= len 0) acc
      (parse-digits (+ start 1) (- len 1)
                    (w32-add (w32-mul acc (w32-from-fixnum 10))
                             (w32-from-fixnum (- (char->integer (string-ref g-bytes start)) 48))))))

(define (reader-read-string)
  (let ((start byte-free))
    (reader-read-string-loop)
    (make-strlike TSTRING start (- byte-free start))))
(define (reader-read-string-loop)
  (let ((c (getchar-)))
    (cond
      ((< c 0) 'done)
      ((= c 34) 'done)
      ((= c 92) (reader-read-string-escape) (reader-read-string-loop))
      (else (bytes-put! (integer->char c)) (reader-read-string-loop)))))
; reader_read_string escapes (reader.c:457-489): \\ \" \0 \a \b \t \n \v \f
; \r \e and \xHH (hex, via reader_read_hex).  Any other char after \ is kept
; verbatim.  Ported byte-for-byte so string literals like nyacc's "\x07"/"\x08"
; (C char-escape table in lex.scm read-c-chlit) decode to 7/8, not 'x' (0x78).
(define (reader-read-string-escape)
  (let ((c (getchar-)))
    (cond
      ((= c 92)  (bytes-put! (integer->char 92)))   ; \\  -> backslash
      ((= c 34)  (bytes-put! (integer->char 34)))   ; \"  -> quote
      ((= c 48)  (bytes-put! (integer->char 0)))    ; \0  -> NUL
      ((= c 97)  (bytes-put! (integer->char 7)))    ; \a  -> alert
      ((= c 98)  (bytes-put! (integer->char 8)))    ; \b  -> backspace
      ((= c 116) (bytes-put! (integer->char 9)))    ; \t  -> tab
      ((= c 110) (bytes-put! (integer->char 10)))   ; \n  -> newline
      ((= c 118) (bytes-put! (integer->char 11)))   ; \v  -> vtab
      ((= c 102) (bytes-put! (integer->char 12)))   ; \f  -> formfeed
      ((= c 114) (bytes-put! (integer->char 13)))   ; \r  -> return
      ((= c 101) (bytes-put! (integer->char 27)))   ; \e  -> escape
      ((= c 120)                                    ; \xHH -> hex (reader_read_hex)
       (bytes-put! (integer->char (w32->fixnum (radix-loop 16 4 (w32-from-fixnum 0))))))
      (else (bytes-put! (integer->char c))))))

; reader_read_hash (reader.c:200): faithful dispatch.  (Radix #x/#b/#o and the
; syntax quotes #'/#`/#, are not yet needed by boot-5 head..B4; they fall to the
; else->read-next-sexp path as placeholders and are added when a rung needs
; them — MesCC/S5 for radix.)
(define (reader-read-hash c)
  (cond ((= c 33) (reader-read-block-comment c (getchar-)) (reader-read-sexp (getchar-)))  ; #!...!#
        ((= c 124) (reader-read-block-comment c (getchar-)) (reader-read-sexp (getchar-))) ; #|...|#
        ((= c 116) cell-t)                     ; #t
        ((= c 102) cell-f)                     ; #f
        ((= c 92) (reader-read-char-literal))  ; #\
        ((= c 58) (reader-read-keyword))       ; #:
        ((= c 98) (reader-read-radix 2 1))     ; #b binary
        ((= c 111) (reader-read-radix 8 3))    ; #o octal
        ((= c 120) (reader-read-radix 16 4))   ; #x hex
        ((= c 40) (list->vector- (reader-read-list (getchar-))))  ; #( ... )
        ((= c 59) (reader-read-sexp (getchar-)) (reader-read-sexp (getchar-)))  ; #; datum comment
        (else (reader-read-sexp (getchar-)))))

; reader_read_character (reader.c:274-365): a char literal is either an octal
; escape (#\NNN, first two chars octal), a hex escape (#\xHH), a named char
; (#\nul, #\return, nyacc abbrevs #\ht/#\np/... — first two chars in [a-z*]),
; or a single literal char.  Ported to match Mes byte-for-byte.
(define (charname-char? c) (or (and (>= c 97) (<= c 122)) (= c 42)))  ; a-z or *
(define (hex-gate-p? p)  ; reader.c:290 predicate that admits #\x as hex
  (or (and (>= p 48) (<= p 57)) (and (>= p 97) (<= p 102)) (= p 70)))
(define (reader-read-char-literal)
  (let ((c (getchar-)) (p (peekchar)))
    (cond ((and (>= c 48) (<= c 55) (>= p 48) (<= p 55))     ; #\NNN octal
           (make-char (char-octal-loop (- c 48))))
          ((and (= c 120) (hex-gate-p? p))                   ; #\xHH hex
           (make-char (w32->fixnum (radix-loop 16 4 (w32-from-fixnum 0)))))
          ((and (charname-char? c) (charname-char? p))       ; #\name
           (reader-read-charname c))
          (else (make-char c)))))
(define (char-octal-loop acc)
  (let ((p (peekchar)))
    (if (and (>= p 48) (<= p 55))
        (char-octal-loop (+ (* acc 8) (- (getchar-) 48)))
        acc)))
(define (reader-read-charname c)
  (let ((start byte-free))
    (bytes-put! (integer->char c))
    (read-charname-loop)
    (let ((len (- byte-free start)))
      (let ((result (make-char (char-name->code start len))))
        (set! byte-free start)
        result))))
(define (read-charname-loop)
  (let ((c (peekchar)))
    (if (charname-char? c)
        (begin (getchar-) (bytes-put! (integer->char c)) (read-charname-loop))
        'ok)))
; The named-char table (reader.c:310-362), including nyacc's old abbreviations.
(define (char-name->code start len)
  (cond ((bytes-eq-rsc start len "*eof*") -1)
        ((bytes-eq-rsc start len "nul") 0)
        ((bytes-eq-rsc start len "alarm") 7)
        ((bytes-eq-rsc start len "backspace") 8)
        ((bytes-eq-rsc start len "tab") 9)
        ((bytes-eq-rsc start len "linefeed") 10)
        ((bytes-eq-rsc start len "newline") 10)
        ((bytes-eq-rsc start len "vtab") 11)
        ((bytes-eq-rsc start len "page") 12)
        ((bytes-eq-rsc start len "return") 13)
        ((bytes-eq-rsc start len "esc") 27)
        ((bytes-eq-rsc start len "space") 32)
        ((bytes-eq-rsc start len "bel") 7)
        ((bytes-eq-rsc start len "bs") 8)
        ((bytes-eq-rsc start len "ht") 9)
        ((bytes-eq-rsc start len "nl") 10)
        ((bytes-eq-rsc start len "vt") 11)
        ((bytes-eq-rsc start len "np") 12)
        ((bytes-eq-rsc start len "cr") 13)
        ((bytes-eq-rsc start len "fs") 28)
        (else (emit-str g-stderr ";;; qmes: char not supported\n") (exit 1))))
(define (bytes-eq-rsc start len str)
  (and (= len (string-length str))
       (bytes-eq-rsc-loop start str 0 len)))
(define (bytes-eq-rsc-loop start str i n)
  (if (= i n) #t
      (if (char=? (string-ref g-bytes (+ start i)) (string-ref str i))
          (bytes-eq-rsc-loop start str (+ i 1) n) #f)))

; reader_read_binary/octal/hex (reader.c:367-442): read a (possibly signed)
; number in the given radix from the port, matching Mes's <<shift accumulation
; (so #xE80A0E65 wraps to the same 32-bit signed value mes-m2 produces).
(define (radix-digit c radix)                   ; digit value, or -1
  (cond ((and (>= c 48) (<= c 57)) (let ((d (- c 48))) (if (< d radix) d -1)))
        ((and (= radix 16) (>= c 97) (<= c 102)) (- c 87))   ; a-f
        ((and (= radix 16) (>= c 65) (<= c 70)) (- c 55))    ; A-F
        (else -1)))
(define (radix-loop radix shift acc)
  (let ((d (radix-digit (peekchar) radix)))
    (if (< d 0) acc
        (begin (getchar-)
               (radix-loop radix shift
                           (w32-add (w32-shl acc shift) (w32-from-fixnum d)))))))
(define (reader-read-radix radix shift)
  (let ((neg (if (= (peekchar) 45) (begin (getchar-) 1) 0)))
    (let ((v (radix-loop radix shift (w32-from-fixnum 0))))
      (make-number-w (if (= neg 1) (w32-sub (w32-from-fixnum 0) v) v)))))

(define (reader-read-keyword)
  (let ((start byte-free))
    (read-token-loop (getchar-))
    (make-strlike TKEYWORD start (- byte-free start))))
; ===========================================================================
; VM registers and the explicit stack (eval-apply.c / gc.c / mes.c)
; ===========================================================================
(define r0 0)   ; env
(define r1 0)   ; expression / value
(define r2 0)   ; scratch / saved datum
(define r3 0)   ; continuation state
(define stkp 0) ; g_stack index, grows down from STACK-SIZE

(define STACK-SIZE 100000)                     ; MES_STACK; allocated in qmain
(define g-stack 0)                             ; raw words holding SCM indices
(define (stack-ref i) (w32->fixnum (vec-raw-ref g-stack i)))
(define (stack-set! i v) (vec-raw-set! g-stack i (w32-from-fixnum v)))

; gc_push_frame / gc_pop_frame (gc.c:685-712), GC_FRAME_SIZE 5.
(define (push-frame!)
  (if (< stkp 5) (qfail))
  (stack-set! (- stkp 1) cell-f)     ; procedure slot (GC_FRAME_PROCEDURE 4)
  (stack-set! (- stkp 2) r0)
  (stack-set! (- stkp 3) r1)
  (stack-set! (- stkp 4) r2)
  (stack-set! (- stkp 5) r3)
  (set! stkp (- stkp 5)))
(define (pop-frame!)
  (set! r3 (stack-ref stkp))
  (set! r2 (stack-ref (+ stkp 1)))
  (set! r1 (stack-ref (+ stkp 2)))
  (set! r0 (stack-ref (+ stkp 3)))
  (set! stkp (+ stkp 5)))
(define (push-cc! p1 p2 a c)
  (let ((x r3))
    (set! r3 c)
    (set! r2 p2)
    (push-frame!)
    (set! r1 p1)
    (set! r0 a)
    (set! r3 x)))

(define GC-FRAME-SIZE 5)
(define GC-FRAME-PROCEDURE 4)

; --- continuation capture/restore (§3.1, eval-apply.c:996-1010, 543-555) ------
; A snapshot is a TVECTOR of the live stack [stkp, STACK-SIZE); the slots are
; ordinary SCMs, so gc-copy relocates them like any vector (§3.2).  Capture uses
; vector-set-x- (the C vector_set_x_) and restore uses vector-ref- (vector_ref_)
; so the wrap/unwrap round-trip is behaviour-identical to Mes.
(define (snapshot-stack)
  (let* ((len (- STACK-SIZE stkp))
         (v (make-vector- len cell-unspec)))
    (snapshot-copy v 0 len)
    v))
(define (snapshot-copy v i len)
  (if (< i len)
      (begin (vector-set-x- v i (stack-ref (+ stkp i)))
             (snapshot-copy v (+ i 1) len))
      'ok))
(define (restore-stack v len i)
  (if (< i len)
      (begin (stack-set! (+ (- STACK-SIZE len) i) (vector-ref- v i))
             (restore-stack v len (+ i 1)))
      'ok))

; --- stack.c port (§3.1 item 4): make-stack / stack-length / stack-ref -------
; A fresh frame/stack record type per call, exactly as stack.c does (no root).
(define (make-frame-type)
  (make-struct cell-symbol-record-type
               (qcons cell-symbol-frame
                      (qcons (qcons cell-symbol-procedure cell-nil) cell-nil))
               cell-unspec))
(define (make-frame index)
  (let ((frame-type (make-frame-type))
        (procedure cell-f))
    (if (not (= index 0))
        (let ((array-index (- STACK-SIZE (* index GC-FRAME-SIZE))))
          (set! procedure (stack-ref (+ array-index GC-FRAME-PROCEDURE))))
        'ok)
    (if (= procedure 0) (set! procedure cell-f) 'ok)
    (make-struct frame-type
                 (qcons cell-symbol-frame (qcons procedure cell-nil))
                 frame-printer-sym)))
(define (make-stack-type)
  (make-struct cell-symbol-record-type
               (qcons cell-symbol-stack
                      (qcons (qcons cell-symbol-frames cell-nil) cell-nil))
               cell-unspec))
(define (make-stack-frames frames i size)
  (if (< i size)
      (begin (vector-set-x- frames i (make-frame i))
             (make-stack-frames frames (+ i 1) size))
      'ok))
(define (b-make-stack)
  (let* ((stack-type (make-stack-type))
         (size (quotient (- STACK-SIZE stkp) GC-FRAME-SIZE))
         (frames (make-vector- size cell-unspec)))
    (make-stack-frames frames 0 size)
    (make-struct stack-type
                 (qcons cell-symbol-stack (qcons frames cell-nil))
                 cell-unspec)))
(define (b-stack-length stack)
  (make-number-fx (vector-length- (struct-ref- stack 3))))
(define (b-stack-ref stack index)
  (vector-ref- (struct-ref- stack 3) (num-fixnum index)))

; values (core.c:115-121): a TVALUES cell over the list of produced values.
(define (b-values x) (alloc TVALUES 0 x))

; ===========================================================================
; Closures / bindings / macros (eval-apply.c, gc.c)
; ===========================================================================
(define (make-closure- args body a)
  (alloc TCLOSURE cell-f
         (qcons (qcons cell-circular a) (qcons args body))))
(define (make-binding- handle lexical-p) (alloc TBINDING handle lexical-p))
(define (binding-handle b) (cell-car b))
(define (binding-lexical-p b) (cell-cdr b))
(define (make-macro name x) (alloc TMACRO x (strlike-bytes name)))
(define (macro-get-handle name)
  (if (= (cell-type name) TSYMBOL) (hashq-get-handle g-macros-table name) cell-f))

; ===========================================================================
; Garbage collection (src/gc.c) — S2.
;
; A literal transliteration of Mes's single-arena copy-up-then-slide-back
; Cheney collector over g-cells (FD §2).  The arena vector is allocated with
; JAM-CELLS of slack above ARENA-CELLS (qmain); a collection copies the live
; set up into that slack ("news"), then slides it back to the base.  The FIXED
; region [0, g-symbol-max) is copied FIRST, cell by cell in index order, so
; every fixed cell lands back at exactly its original index — qmes's ~90
; fixed-cell globals (cell-nil, cell-vm-*, cell-symbol-*) are numerically
; stable across GC and never need patching.  Forwarding uses TBROKEN-HEART:
; a copied cell's old slot becomes [TBROKEN-HEART | new-index | *].
;
; Collection runs ONLY at the three gc-check sites (§2.4 rule 1); all live
; SCMs are then reachable from the root set, so precise copying needs no host
; frame scan.  Cell INDICES are small fixnums; TNUMBER/TCHAR payloads are raw
; w32 words — the flip therefore relocates only pointer fields (small indices)
; and copies every other word raw, never round-tripping a value through fixnum.
; ===========================================================================
(define GC-SAFETY 10000)                        ; = ARENA-CELLS/100 (set in qmain)
(define JAM-CELLS 100000)                        ; = ARENA-CELLS/10  (set in qmain)
(define g-symbol-max 0)                          ; end of the fixed region (qmain)
(define g-news 0)                                ; news-space base for a collection
(define gc-dbg-scan 0)                            ; last cell scanned (debug guard)
(define gc-count 0)
(define qmes-gc-stress 0)                        ; N>0: collect every N gc-checks
(define gc-stress-ctr 0)

; --- pointer-field classification (gc.c type lists) ------------------------
; car is a pointer for {TMACRO, TPAIR, TREF, TBINDING} (gc.c:386-389).
(define (gc-car-ptr? t)
  (or (= t TMACRO) (= t TPAIR) (= t TREF) (= t TBINDING)))
; cdr is a pointer, in the gc_loop scan set (gc.c:556-568): TSTRUCT/TVECTOR are
; handled by gc-copy (bodies copied inline), and qmes TBYTES has a pool offset,
; not a pointer, in its cdr — both excluded here.
(define (gc-cdr-ptr-loop? t)
  (or (= t TCLOSURE) (= t TCONTINUATION) (= t TKEYWORD) (= t TMACRO)
      (= t TPAIR) (= t TPORT) (= t TSPECIAL) (= t TSTRING)
      (= t TSYMBOL) (= t TVALUES)))
; cdr relocation set at flip (gc_cellcpy, gc.c:393-406): adds TSTRUCT/TVECTOR
; (their cdr is the body index), still excludes TBYTES (pool offset).
(define (gc-cdr-ptr-flip? t)
  (or (gc-cdr-ptr-loop? t) (= t TSTRUCT) (= t TVECTOR)))

; gc-copy (gc.c:473-518): copy `old` to news, leave a broken-heart forward.
(define (gc-copy old)
  (if (and (not (= qmes-debug-err 0))
           (or (< old 0) (>= old (+ ARENA-CELLS JAM-CELLS))))
      (begin (emit-str g-stderr ";;; gc-copy bad index ") (emit-number g-stderr old)
             (emit-str g-stderr " scan=") (emit-number g-stderr gc-dbg-scan)
             (emit-str g-stderr " gc-count=") (emit-number g-stderr gc-count)
             (emit g-stderr 10) (exit 3))
      'ok)
  (if (= (cell-type old) TBROKEN-HEART)
      (cell-car old)                             ; already forwarded
      (let ((new (alloc-n 1)) (t (cell-type old)))
        (copy-cell! new old)
        (cond
          ((or (= t TSTRUCT) (= t TVECTOR))
           (let ((len (cell-car old)) (oldbody (cell-cdr old)))
             (set-cdr! new cell-free)            ; body follows the header
             (gc-copy-body oldbody 0 len)))
          ((= t TBYTES)
           (let ((len (cell-car old)) (oldoff (cell-cdr old)))
             (set-cdr! new gc-to-byte-free)      ; new offset in the target pool
             (gc-copy-bytes oldoff gc-to-byte-free len)
             (set! gc-to-byte-free (+ gc-to-byte-free len))))
          (else 'ok))
        (set-type! old TBROKEN-HEART)
        (set-car! old new)
        new)))
(define (gc-copy-body oldbody i len)
  (if (< i len)
      (begin (copy-cell! (alloc-n 1) (+ oldbody i)) (gc-copy-body oldbody (+ i 1) len))
      'ok))
(define (gc-copy-bytes src dst len)
  (if (> len 0)
      (begin (string-set! gc-to-pool dst (string-ref g-bytes src))
             (gc-copy-bytes (+ src 1) (+ dst 1) (- len 1)))
      'ok))

; gc-loop (gc.c:534-580): Cheney scan of the news space; relocate pointer
; fields, growing the news frontier as gc-copy allocates.
; Niladic Cheney scan (cursor gc-scan in a global) with periodic host-heap
; resets.  cell-free grows as gc-copy allocates; re-read each iteration.
(define (gc-loop)
  (gc-tick!)
  (if (< gc-scan cell-free)
      (let ((t (cell-type gc-scan)))
        (set! gc-dbg-scan gc-scan)
        (if (gc-car-ptr? t) (set-car! gc-scan (gc-copy (cell-car gc-scan))) 'ok)
        (if (gc-cdr-ptr-loop? t) (set-cdr! gc-scan (gc-copy (cell-cdr gc-scan))) 'ok)
        (set! gc-scan (+ gc-scan 1))
        (gc-loop))
      'ok))

; gc-flip (gc.c:446-471): slide news back to the base, subtracting `dist` from
; every pointer field.  Non-pointer words are copied raw (w32 payloads intact).
; Niladic flip cellcpy (cursor gc-cc-j, bounds gc-cc-upto, delta gc-dist in
; globals) with periodic host-heap resets.
(define (gc-cellcpy)
  (gc-tick!)
  (if (< gc-cc-j gc-cc-upto)
      (let ((t (w32->fixnum (raw-ref gc-cc-j 0))) (dest (- gc-cc-j gc-dist)))
        (raw-set! dest 0 (raw-ref gc-cc-j 0))
        (if (gc-car-ptr? t)
            (raw-set! dest 1 (w32-from-fixnum (- (w32->fixnum (raw-ref gc-cc-j 1)) gc-dist)))
            (raw-set! dest 1 (raw-ref gc-cc-j 1)))
        (if (gc-cdr-ptr-flip? t)
            (raw-set! dest 2 (w32-from-fixnum (- (w32->fixnum (raw-ref gc-cc-j 2)) gc-dist)))
            (raw-set! dest 2 (raw-ref gc-cc-j 2)))
        (set! gc-cc-j (+ gc-cc-j 1))
        (gc-cellcpy))
      'ok))
(define (gc-fix-stack i dist)
  (if (< i STACK-SIZE)
      (begin (stack-set! i (- (stack-ref i) dist)) (gc-fix-stack (+ i 1) dist))
      'ok))
(define (gc-flip)
  (let ((dist g-news))                           ; news base index; base is 0
    ; niladic gc-cellcpy over [g-news, cell-free): state in globals, reset to a
    ; floor captured here (below is this gc-flip frame, preserved on return).
    (set! gc-dist dist)
    (set! gc-cc-upto cell-free)
    (set! gc-cc-j g-news)
    (set! gc-floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
    (set! gc-k GC-RESET-K)
    (gc-cellcpy)
    (let ((tmp g-bytes)) (set! g-bytes gc-to-pool) (set! gc-to-pool tmp))
    (set! byte-free gc-to-byte-free)
    (if (< byte-free BYTE-POOL-HI) (set! gc-pressure 0) 'ok)
    (set! cell-free (- cell-free dist))
    (set! g-symbols (- g-symbols dist))
    (set! g-macros-table (- g-macros-table dist))
    (set! g-ports (- g-ports dist))
    (set! hash-table-type-struct (- hash-table-type-struct dist))
    (set! variable-type-struct (- variable-type-struct dist))
    (set! builtin-type-struct (- builtin-type-struct dist))
    (set! m0 (- m0 dist))
    (set! m1 (- m1 dist))
    (gc-fix-stack stkp dist)))

; gc- (gc.c:592-644): roots in gc.c:627-641 order.  The fixed region first (so
; it stays put), then g-symbols(obarray) / g-macros-table / g-ports / the three
; type structs / m0 / m1, then the live stack [stkp, STACK-SIZE) — R0..R3 ride
; the stack via the push-frame in qgc.  new_cell_nil = g-news.
(define (gc-copy-fixed i)
  (if (< i g-symbol-max) (begin (gc-copy i) (gc-copy-fixed (+ i 1))) 'ok))
(define (gc-copy-stack i)
  (if (< i STACK-SIZE)
      (begin (stack-set! i (gc-copy (stack-ref i))) (gc-copy-stack (+ i 1)))
      'ok))
(define (gc-)
  (set! g-news cell-free)
  (set! gc-to-pool (if (= g-bytes g-bytes-a) g-bytes-b g-bytes-a))
  (set! gc-to-byte-free 0)
  (gc-copy-fixed 0)
  (set! g-symbols (gc-copy g-symbols))
  (set! g-macros-table (gc-copy g-macros-table))
  (set! g-ports (gc-copy g-ports))
  (set! hash-table-type-struct (gc-copy hash-table-type-struct))
  (set! variable-type-struct (gc-copy variable-type-struct))
  (set! builtin-type-struct (gc-copy builtin-type-struct))
  (set! m0 (gc-copy m0))
  (set! m1 (gc-copy m1))
  (gc-copy-stack stkp)
  ; niladic Cheney scan from g-news: cursor gc-scan global, host-heap reset to a
  ; floor captured here (mark+64).  The pre-loop root copies above sit below the
  ; mark and are not freed (bounded: fixed region + a handful of roots).
  (set! gc-scan g-news)
  (set! gc-floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
  (set! gc-k GC-RESET-K)
  (gc-loop)
  (gc-flip)
  (set! gc-count (+ gc-count 1)))

; gc (gc.c:646-682): bracket gc- with a frame that roots R0..R3 on the stack.
(define (qgc)
  (set! in-gc-flag 1)
  (push-frame!)
  (gc-)
  (pop-frame!)
  (set! in-gc-flag 0)
  cell-unspec)

; gc-check (gc.c:582-589): collect when the arena is within GC-SAFETY of full,
; or the byte pool is under pressure, or gc-stress forces it (§2.4).
(define (gc-want?)
  (cond ((not (= qmes-gc-stress 0))
         (set! gc-stress-ctr (+ gc-stress-ctr 1))
         (if (>= gc-stress-ctr qmes-gc-stress)
             (begin (set! gc-stress-ctr 0) #t)
             #f))
        ((>= (+ cell-free GC-SAFETY) ARENA-CELLS) #t)
        ((not (= gc-pressure 0)) #t)
        (else #f)))
(define (gc-check)
  (if (gc-want?) (qgc) cell-unspec))

; gc-stats (gc.c:137-150): an alist of gc-count / arena-free / arena-size.
(define (b-gc-stats)
  (let ((used cell-free))
    (acons (intern-rsc "gc-count") (make-number-fx gc-count)
      (acons (intern-rsc "arena-free") (make-number-fx (- ARENA-CELLS used))
        (acons (intern-rsc "arena-size") (make-number-fx ARENA-CELLS) cell-nil)))))
(define (macro-set-x name value) (hashq-set-x g-macros-table name value))
(define (get-macro name)
  (let ((m (macro-get-handle name)))
    (if (not (= m cell-f)) (cell-car (cell-cdr m)) cell-f)))

; ===========================================================================
; Errors — any error path is a divergence for the gate; print + exit 1.
; ===========================================================================
; QMES_DEBUG_ERR (set at startup) turns silent error exits into a stderr
; diagnostic — used only for boot-ladder bring-up; never fires on a passing
; rung (references have empty stderr), so it cannot affect a byte-exact gate.
(define qmes-debug-err 0)
(define (qerror-diag tag x)
  (if (= qmes-debug-err 0) 'ok
      (begin (emit-str g-stderr ";;; qmes-error ") (emit-str g-stderr tag)
             (emit g-stderr 32) (display- x g-stderr 1) (emit g-stderr 10))))
(define (qerror-unbound x) (qerror-diag "unbound" x) (qfail))
(define (qerror-args f) (qerror-diag "wrong-args" f) (qfail))
(define (qerror-type e) (qerror-diag "wrong-type" e) (qfail))

; ===========================================================================
; Leaf helpers (pairlis, append2, check-formals, check-apply, lookup, set!)
; ===========================================================================
(define (pairlis x y a)
  (cond ((= x cell-nil) a)
        ((not (= (cell-type x) TPAIR)) (qcons (qcons x y) a))
        (else (qcons (qcons (cell-car x) (cell-car y))
                     (pairlis (cell-cdr x) (cell-cdr y) a)))))

(define (append2 x y)
  (if (= x cell-nil) y (qcons (cell-car x) (append2 (cell-cdr x) y))))

(define (check-formals f formals args)
  (let ((flen (if (= (cell-type formals) TNUMBER)
                  (num-fixnum formals) (length- formals)))
        (alen (length- args)))
    (if (and (not (= alen flen)) (not (= alen -1)) (not (= flen -1)))
        (qerror-args f)
        cell-unspec)))

(define (check-apply f e)
  (let ((bad
         (cond ((or (= f cell-f) (= f cell-t)) #t)
               ((= f cell-nil) #t)
               ((= f cell-unspec) #t)
               ((= f cell-undefined) #t)
               (else (let ((t (cell-type f)))
                       (or (= t TCHAR) (= t TNUMBER) (= t TSTRING)
                           (= t TBROKEN-HEART)))))))
    (if bad (qerror-type e) cell-unspec)))

(define (lookup-binding name define-p)
  (let ((handle (qassq name r0)))
    (if (not (= handle cell-f))
        (make-binding- handle 1)
        (let ((var (current-module-variable name define-p)))
          (if (= var cell-f) cell-f
              (make-binding- (qcons name var) 0))))))

(define (lookup-value name)
  (let ((b (lookup-binding name cell-f)))
    (if (not (= b cell-f))
        (if (not (= (binding-lexical-p b) 0))
            (cell-cdr (binding-handle b))
            (variable-ref (cell-cdr (binding-handle b))))
        cell-undefined)))

(define (assert-defined x e)
  (if (= e cell-undefined) (qerror-unbound x) e))

(define (set-x x e define-p)
  (let ((binding (if (= (cell-type x) TBINDING) x (lookup-binding x cell-f))))
    (if (= binding cell-f)
        (qerror-unbound x)
        (if (not (= (binding-lexical-p binding) 0))
            (begin (set-cdr! (binding-handle binding) e) cell-unspec)
            (let ((variable (cell-cdr (binding-handle binding))))
              (if (and (= define-p 0) (= (variable-ref variable) cell-undefined))
                  (qerror-unbound (cell-car (binding-handle binding)))
                  (begin (variable-set-x variable e) cell-unspec)))))))

; ===========================================================================
; expand_variable (eval-apply.c:247-379, §3.6) — rewrite free symbols in place
; into TBINDING cells (creating M0 variables for still-undefined names).
; Runs as a leaf over the r1/r2/r3 globals, bracketed by push/pop-frame.
; ===========================================================================
(define (add-formals formals x)
  (cond ((= (cell-type x) TPAIR)
         (add-formals (qcons (cell-car x) formals) (cell-cdr x)))
        ((= (cell-type x) TSYMBOL) (qcons x formals))
        (else formals)))
(define (formal-p x formals)
  (cond ((= (cell-type formals) TSYMBOL) (if (= x formals) 1 0))
        ((= (cell-type formals) TPAIR)
         (if (= (cell-car formals) x) 1 (formal-p x (cell-cdr formals))))
        (else 0)))

(define (ev-loop1 v)
  (if (= (cell-type v) TPAIR)
      (let ((a (cell-car v)))
        (if (= a cell-symbol-quote)
            'break
            (begin
              (if (and (= (cell-type a) TPAIR)
                       (or (= (cell-car a) cell-symbol-define)
                           (= (cell-car a) cell-symbol-define-macro)))
                  (if (= (cell-type (cell-car (cell-cdr a))) TPAIR)
                      (set! r2 (qcons (cell-car (cell-car (cell-cdr a))) r2))
                      (set! r2 (qcons (cell-car (cell-cdr a)) r2)))
                  'ok)
              (ev-loop1 (cell-cdr v)))))
      'done))
(define (ev-loop2 top-p)
  (if (not (= (cell-type r1) TPAIR))
      'done
      (let ((a (cell-car r1)))
        (cond
          ((= (cell-type a) TPAIR)
           (begin (set! r3 (qcons (qcons a r2) r3))
                  (set! r1 (cell-cdr r1)) (ev-loop2 0)))
          ((= a cell-symbol-lambda)
           (begin (set! r2 (add-formals r2 (cell-car (cell-cdr r1))))
                  (set! r1 (cell-cdr r1))
                  (set! r1 (cell-cdr r1))
                  (ev-loop2 0)))
          ((or (= a cell-symbol-define) (= a cell-symbol-define-macro))
           (let* ((f0 (cell-car (cell-cdr r1)))
                  (f (if (not (= top-p 0))
                         (if (= (cell-type f0) TPAIR) (cell-cdr f0) cell-nil)
                         f0)))
             (set! r2 (add-formals r2 f))
             (set! r1 (cell-cdr r1))
             (set! r1 (cell-cdr r1))
             (ev-loop2 0)))
          ((= a cell-symbol-quote) 'return)
          ((and (= (cell-type a) TSYMBOL)
                (not (= a cell-symbol-current-environment))
                (= (formal-p a r2) 0))
           (begin
             (let ((v (lookup-binding a cell-f)))
               (if (not (= v cell-f))
                   (set-car! r1 v)
                   (set-car! r1 (lookup-binding a cell-t))))
             (set! r1 (cell-cdr r1)) (ev-loop2 0)))
          (else (begin (set! r1 (cell-cdr r1)) (ev-loop2 0)))))))
(define (expand-variable- top-p)
  (ev-loop1 r1)
  (ev-loop2 top-p))
(define (ev-worklist)
  (if (= (cell-type r3) TPAIR)
      (begin
        (set! r1 (cell-car (cell-car r3)))
        (set! r2 (cell-cdr (cell-car r3)))
        (set! r3 (cell-cdr r3))
        (expand-variable- 0)
        (ev-worklist))
      'done))
(define (expand-variable x formals)
  (push-frame!)
  (set! r1 x) (set! r2 formals) (set! r3 cell-nil)
  (expand-variable- 1)
  (ev-worklist)
  (pop-frame!)
  cell-unspec)

; ===========================================================================
; eq? and the printer (subset of core.c eq_p, display.c)
; ===========================================================================
; string_equal_p (string.c:66) over TSTRING/TKEYWORD.
(define (string-eq-p a b)
  (cond ((= a b) cell-t)
        ((= (strlike-bytes a) (strlike-bytes b)) cell-t)
        ((and (= (strlike-len a) 0) (= (strlike-len b) 0)) cell-t)
        ((and (= (strlike-len a) (strlike-len b))
              (bytes-equal? (strlike-offset a) (strlike-len a)
                            (strlike-offset b) (strlike-len b))) cell-t)
        (else cell-f)))

; memq (lib.c:70)
(define (memq- x a)
  (let ((t (cell-type x)))
    (cond ((or (= t TCHAR) (= t TNUMBER)) (memq-value x a))
          ((= t TKEYWORD) (memq-keyword x a))
          (else (memq-id x a)))))
(define (memq-value x a)
  (cond ((= a cell-nil) cell-f)
        ((num=? x (cell-car a)) a)
        (else (memq-value x (cell-cdr a)))))
(define (memq-keyword x a)
  (cond ((= a cell-nil) cell-f)
        ((and (= (cell-type (cell-car a)) TKEYWORD)
              (= (string-eq-p x (cell-car a)) cell-t)) a)
        (else (memq-keyword x (cell-cdr a)))))
(define (memq-id x a)
  (cond ((= a cell-nil) cell-f)
        ((= x (cell-car a)) a)
        (else (memq-id x (cell-cdr a)))))

; equal2_p (lib.c:105)
(define (equal2- a b)
  (cond ((= a b) cell-t)
        ((and (= (cell-type a) TPAIR) (= (cell-type b) TPAIR))
         (if (= (equal2- (cell-car a) (cell-car b)) cell-t)
             (equal2- (cell-cdr a) (cell-cdr b))
             cell-f))
        ((and (= (cell-type a) TSTRING) (= (cell-type b) TSTRING))
         (string-eq-p a b))
        ((and (= (cell-type a) TVECTOR) (= (cell-type b) TVECTOR))
         (equal2-vector a b))
        (else (eq-p a b))))
(define (equal2-vector a b)
  (if (not (= (vector-length- a) (vector-length- b))) cell-f
      (equal2-vec-loop a b 0 (vector-length- a))))
(define (equal2-vec-loop a b i n)
  (cond ((= i n) cell-t)
        ((= (equal2- (vector-ref- a i) (vector-ref- b i)) cell-f) cell-f)
        (else (equal2-vec-loop a b (+ i 1) n))))

; string_append (string.c:199) — concatenate a list of strings into g-bytes
(define (string-append- x)
  (let ((start byte-free))
    (sa-loop x)
    (make-strlike TSTRING start (- byte-free start))))
(define (sa-loop x)
  (if (= x cell-nil) 'ok (begin (sa-copy (cell-car x)) (sa-loop (cell-cdr x)))))
(define (sa-copy s) (sa-copy-loop (strlike-offset s) (strlike-len s)))
(define (sa-copy-loop off len)
  (if (> len 0)
      (begin (bytes-put! (string-ref g-bytes off)) (sa-copy-loop (+ off 1) (- len 1)))
      'ok))

(define (eq-p x y)
  (if (= x y) cell-t
      (let ((t (cell-type x)))
        (cond
          ((= t TKEYWORD)
           (if (= (cell-type y) TKEYWORD) (string-eq-p x y) cell-f))
          ((= t TCHAR)
           (if (and (= (cell-type y) TCHAR) (w32-eq? (num-value x) (num-value y)))
               cell-t cell-f))
          ((= t TNUMBER)
           (if (and (= (cell-type y) TNUMBER) (num=? x y))
               cell-t cell-f))
          (else cell-f)))))

(define g-outc (make-string 1))
(define (emit fd code)
  (string-set! g-outc 0 (integer->char code))
  (sys-write fd g-outc 1))
(define (emit-bytes fd off len)
  (if (> len 0)
      (begin (emit fd (char->integer (string-ref g-bytes off)))
             (emit-bytes fd (+ off 1) (- len 1)))
      'ok))
(define (emit-str fd str) (emit-str-loop fd str 0 (string-length str)))
(define (emit-str-loop fd str i n)
  (if (< i n)
      (begin (emit fd (char->integer (string-ref str i)))
             (emit-str-loop fd str (+ i 1) n))
      'ok))
(define (emit-number fd n)
  (if (< n 0) (begin (emit fd 45) (emit-digits fd (- 0 n))) (emit-digits fd n)))
(define (emit-digits fd n)
  (if (< n 10) (emit fd (+ 48 n))
      (begin (emit-digits fd (quotient n 10)) (emit fd (+ 48 (remainder n 10))))))
; TNUMBER printer seam (qmes-w64.scm widens it to two words).
(define (emit-tnumber fd x) (emit-number fd (num-fixnum x)))

(define (display- x fd w)
  (let ((t (cell-type x)))
    (cond
      ((= t TNUMBER) (emit-tnumber fd x))
      ((= t TCHAR)
       (if (= w 1) (begin (emit fd 35) (emit fd 92) (emit fd (char-value x)))
           (emit fd (char-value x))))
      ((= t TSTRING)
       (if (= w 1)
           (begin (emit fd 34) (emit-bytes fd (strlike-offset x) (strlike-len x)) (emit fd 34))
           (emit-bytes fd (strlike-offset x) (strlike-len x))))
      ((or (= t TSYMBOL) (= t TSPECIAL))
       (emit-bytes fd (strlike-offset x) (strlike-len x)))
      ((= t TKEYWORD)
       (begin (emit fd 35) (emit fd 58) (emit-bytes fd (strlike-offset x) (strlike-len x))))
      ((= t TPAIR) (display-pair x fd w))
      ((= t TVECTOR) (display-vector x fd w))
      ((= t TCLOSURE) (emit-str fd "#<closure>"))
      ((= t TSTRUCT)
       (if (= (builtin-p x) cell-t) (builtin-printer fd x) (emit-str fd "#<struct>")))
      (else (emit-str fd "#<?>")))))
; builtin_printer (builtins.c:66): #<procedure NAME _>  /  #<procedure NAME (_ _)>
(define (builtin-printer fd b)
  (emit-str fd "#<procedure ")
  (let ((nm (builtin-name- b)))
    (emit-bytes fd (strlike-offset nm) (strlike-len nm)))
  (emit fd 32)
  (let ((arity (num-fixnum (builtin-arity- b))))
    (if (< arity 0) (emit fd 95)
        (begin (emit fd 40) (builtin-printer-args fd arity 0) (emit fd 41))))
  (emit fd 62))
(define (builtin-printer-args fd arity i)
  (if (< i arity)
      (begin (if (> i 0) (emit fd 32)) (emit fd 95)
             (builtin-printer-args fd arity (+ i 1)))
      'ok))
(define (display-pair x fd w)
  (emit fd 40)
  (display-pair-loop x fd w)
  (emit fd 41))
(define (display-pair-loop x fd w)
  (display- (cell-car x) fd w)
  (let ((d (cell-cdr x)))
    (cond ((= d cell-nil) 'done)
          ((= (cell-type d) TPAIR) (begin (emit fd 32) (display-pair-loop d fd w)))
          (else (begin (emit-str fd " . ") (display- d fd w))))))
(define (display-vector x fd w)
  (emit fd 35) (emit fd 40)
  (display-vec-loop x fd w 0 (vector-length- x))
  (emit fd 41))
(define (display-vec-loop x fd w i n)
  (if (< i n)
      (begin (if (> i 0) (emit fd 32))
             (display- (vector-ref- x i) fd w)
             (display-vec-loop x fd w (+ i 1) n))
      'ok))

; ===========================================================================
; Arithmetic (math.c) — fold over w32 TNUMBER payloads.
; ===========================================================================
(define w32-0 0)   ; set in init to (w32-from-fixnum 0)
(define (w32-neg a) (w32-sub w32-0 a))

(define (b-plus x) (make-number-w (plus-loop x w32-0)))
(define (plus-loop x acc)
  (if (= x cell-nil) acc
      (plus-loop (cell-cdr x) (w32-add acc (num-value (cell-car x))))))
(define (b-minus x)
  (let ((n0 (num-value (cell-car x))) (rest (cell-cdr x)))
    (if (= rest cell-nil)
        (make-number-w (w32-neg n0))
        (make-number-w (minus-loop rest n0)))))
(define (minus-loop x acc)
  (if (= x cell-nil) acc
      (minus-loop (cell-cdr x) (w32-sub acc (num-value (cell-car x))))))
(define (b-is x)
  (if (= x cell-nil) cell-t (is-loop (cell-cdr x) (num-value (cell-car x)))))
(define (is-loop x n)
  (cond ((= x cell-nil) cell-t)
        ((w32-eq? (num-value (cell-car x)) n) (is-loop (cell-cdr x) n))
        (else cell-f)))

; core:car / core:cdr (lib.c:39-55): raw field accessors.  For TPAIR/TBINDING
; car returns the field directly; for TPAIR/TCLOSURE cdr returns the field
; directly; otherwise the raw field word is wrapped in a fresh TNUMBER.
(define (b-core-car x)
  (if (or (= (cell-type x) TPAIR) (= (cell-type x) TBINDING))
      (cell-car x)
      (make-number-w (raw-ref x 1))))
(define (b-core-cdr x)
  (if (or (= (cell-type x) TPAIR) (= (cell-type x) TCLOSURE))
      (cell-cdr x)
      (make-number-w (raw-ref x 2))))

; multiply (math.c:215): fold with w32-mul, identity 1.
(define (b-mult x) (make-number-w (mult-loop x (w32-from-fixnum 1))))
(define (mult-loop x acc)
  (if (= x cell-nil) acc
      (mult-loop (cell-cdr x) (w32-mul acc (num-value (cell-car x))))))
; greater_p (math.c:41): (> a b c ...) -> #t iff strictly decreasing.
; C: v >= n -> cell_f; n = v.  v >= n  <=>  not (v < n).
(define (b-greater x)
  (if (= x cell-nil) cell-t (greater-loop (cell-cdr x) (num-value (cell-car x)))))
(define (greater-loop x n)
  (cond ((= x cell-nil) cell-t)
        (else (let ((v (num-value (cell-car x))))
                (if (w32-lt? v n) (greater-loop (cell-cdr x) v) cell-f)))))
; less_p (math.c:63): (< a b c ...) -> #t iff strictly increasing.
; C: v <= n -> cell_f; n = v.  v <= n  <=>  not (n < v).
(define (b-less x)
  (if (= x cell-nil) cell-t (less-loop (cell-cdr x) (num-value (cell-car x)))))
(define (less-loop x n)
  (cond ((= x cell-nil) cell-t)
        (else (let ((v (num-value (cell-car x))))
                (if (w32-lt? n v) (less-loop (cell-cdr x) v) cell-f)))))
; logand/logior/logxor (math.c): fold, identities -1 / 0 / 0.
(define (b-logand x) (make-number-w (logand-loop x (w32-from-fixnum -1))))
(define (logand-loop x acc)
  (if (= x cell-nil) acc (logand-loop (cell-cdr x) (w32-and acc (num-value (cell-car x))))))
(define (b-logior x) (make-number-w (logior-loop x w32-0)))
(define (logior-loop x acc)
  (if (= x cell-nil) acc (logior-loop (cell-cdr x) (w32-or acc (num-value (cell-car x))))))
(define (b-logxor x) (make-number-w (logxor-loop x w32-0)))
(define (logxor-loop x acc)
  (if (= x cell-nil) acc (logxor-loop (cell-cdr x) (w32-xor acc (num-value (cell-car x))))))
; lognot (math.c): ~n.  Seam so qmes-w64.scm can widen it.
(define (b-lognot x) (make-number-w (w32-not (num-value (cell-car x)))))
; ash (math.c): n<<count if count>=0 else n>>(-count) (arithmetic).
; w32-shl/shr/sar take a plain fixnum shift count (not a w32 box).
(define (b-ash a b)
  (let ((n (num-value a)) (c (w32->fixnum (num-value b))))
    (if (>= c 0)
        (make-number-w (w32-shl n (remainder c 32)))
        (make-number-w (w32-sar n (remainder (- 0 c) 32))))))
; modulo (math.c:188): result has sign of the divisor's magnitude algorithm;
; while (n<0) n+=w;  u = (n!=0)? n%w : 0;  if divisor<0 negate.
(define (b-modulo a b)
  (let ((n (num-value a)) (v (num-value b)))
    (let* ((sign-p (w32-lt? v w32-0))
           (w (if sign-p (w32-neg v) v)))
      (let ((n2 (mod-raise n w)))
        (let ((u (if (w32-eq? n2 w32-0) w32-0 (w32-urem n2 w))))
          (make-number-w (if sign-p (w32-neg u) u)))))))
(define (mod-raise n w)                          ; while (n<0) n = n + w
  (if (w32-lt? n w32-0) (mod-raise (w32-add n w) w) n))
; divide (math.c:143): unsigned magnitude division, sign folded across args.
; n starts 1; first arg sets n; then for each arg: sign_p toggles per C rule,
; and u = u / |v| (skipped when |v|==1 or u==0), div-by-zero errors.
(define (b-div x)
  (if (= x cell-nil) (make-number-fx 1)
      (let* ((n0 (num-value (cell-car x)))
             (neg0 (w32-lt? n0 w32-0))
             (u0 (if neg0 (w32-neg n0) n0)))
        (b-div-loop (cell-cdr x) u0 (if neg0 1 0)))))
(define (b-div-loop x u sign)                    ; sign: 0 or 1
  (if (= x cell-nil)
      (make-number-w (if (= sign 1) (w32-neg u) u))
      (let ((v (num-value (cell-car x))))
        ; sign_p = (sign_p && v>0) || (!sign_p && v<0); w = (size_t)v (raw).
        (let ((nsign (if (or (and (= sign 1) (w32-lt? w32-0 v))
                             (and (= sign 0) (w32-lt? v w32-0))) 1 0)))
          (cond ((w32-eq? v w32-0) (qerror-type (cell-car x)))  ; divide-by-zero
                ((w32-eq? u w32-0) (make-number-w (if (= nsign 1) (w32-neg u) u)))
                ((w32-eq? v (w32-from-fixnum 1)) (b-div-loop (cell-cdr x) u nsign))
                (else (b-div-loop (cell-cdr x) (w32-uquot u v) nsign)))))))

; ===========================================================================
; String / list / keyword leaf builtins (string.c, lib.c, vector.c)
; ===========================================================================
(define (bytes->list- off len)
  (if (= len 0) cell-nil
      (qcons (make-char (char->integer (string-ref g-bytes off)))
             (bytes->list- (+ off 1) (- len 1)))))
(define (string->list- s) (bytes->list- (strlike-offset s) (strlike-len s)))
; string-ref (string.c:227): p[i] as a char (bounds error if i>size).
(define (b-string-ref s k)
  (let ((i (num-fixnum k)))
    (if (> i (strlike-len s)) (qerror-type k)
        (make-char (char->integer (string-ref g-bytes (+ (strlike-offset s) i)))))))
; string-set! (string.c:240): p[i] = c (in-place mutation of the byte pool).
(define (b-string-set s k c)
  (let ((i (num-fixnum k)))
    (if (> i (strlike-len s)) (qerror-type k)
        (begin (string-set! g-bytes (+ (strlike-offset s) i) (integer->char (char-value c)))
               cell-unspec))))
(define (list->string- x)
  (let ((start byte-free))
    (l2s-loop x)
    (make-strlike TSTRING start (- byte-free start))))
(define (l2s-loop x)
  (if (= x cell-nil) 'ok
      (begin (bytes-put! (integer->char (char-value (cell-car x)))) (l2s-loop (cell-cdr x)))))
; symbol/keyword/string share the (length . tbytes-cell) layout: retag.
(define (retag t s) (alloc t (cell-car s) (cell-cdr s)))
; vector->list (vector.c:117): deref TREF only, build from the end.
(define (vector->list- v) (v2l-loop v (vector-length- v) cell-nil))
(define (v2l-loop v i acc)
  (if (= i 0) acc
      (let ((e (+ (vector-body v) (- i 1))))
        (v2l-loop v (- i 1)
                  (qcons (if (= (cell-type e) TREF) (cell-car e) e) acc)))))

; ===========================================================================
; Ports (posix.c) — string input ports + fd output ports.
;   g-stdin: a fixnum.  >= 0 = a real fd; < 0 identifies a string port
;   (id = -length(g-ports-before-add) - 2).  TPORT = [TPORT | id | string-cell];
;   readchar consumes the string cell (posix.c:89).
; ===========================================================================
(define g-stdin 0)
(define g-stdout 1)
(define g-stderr 2)
(define g-ports 0)             ; Mes list, cell-nil terminated

(define (make-string-port strcell)
  (alloc TPORT (- (- 0 (length- g-ports)) 2) strcell))
(define (b-open-input-string strcell)
  (let ((port (make-string-port strcell)))
    (set! g-ports (qcons port g-ports))
    port))
(define (find-port x)
  (if (= x cell-nil) cell-f
      (if (= (cell-car (cell-car x)) g-stdin) (cell-car x) (find-port (cell-cdr x)))))
(define (b-current-input-port)
  (if (>= g-stdin 0) (make-number-fx g-stdin) (find-port g-ports)))
; Mes stores the unread/peek pushback PER PORT (posix.c readchar/unreadchar back
; up the port's own string).  qmes's rd-pb is a single global, so a pending
; pushback would leak into the next port across set-current-input-port (this
; broke nyacc's CPP reader: read-cpp-line unreads '\n' on the C source, then
; cpp-line->stmt switches to the directive string port and read the leaked
; '\n' instead of the directive).  Before switching, hand the pushback back to
; the current string port the Mes way (offset-1, len+1, write the char), so it
; is read again when we return to that port.
(define (flush-pushback!)
  (if (= rd-pb -2) 'ok
      (let ((port (find-port g-ports)))
        (if (= port cell-f) (set! rd-pb -2)
            (let ((s (cell-cdr port)))
              (let ((off (strlike-offset s)) (len (strlike-len s)))
                (string-set! g-bytes (- off 1) (integer->char rd-pb))
                (set-cdr! port (make-strlike TSTRING (- off 1) (+ len 1)))
                (set! rd-pb -2)))))))
(define (b-set-current-input-port port)
  (let ((prev (b-current-input-port)))
    (flush-pushback!)
    (cond ((= (cell-type port) TNUMBER)
           (let ((p (num-fixnum port))) (set! g-stdin (if (= p 0) 0 p))))
          ((= (cell-type port) TPORT) (set! g-stdin (cell-car port)))
          (else 'ok))
    prev))
; read-string (string.c:169) [arity n]: read all of the current input port
; (through the reader's pushback, so it composes with the reader).
(define (b-read-string x)
  (let ((start byte-free))
    (read-string-all)
    (make-strlike TSTRING start (- byte-free start))))
(define (read-string-all)
  (let ((c (getchar-)))
    (if (< c 0) 'done (begin (bytes-put! (integer->char c)) (read-string-all)))))
; output side: a port arg is a number (fd); write to it (fd 2 -> stderr).
(define (port-fd port)
  (if (= (cell-type port) TNUMBER)
      (let ((v (num-fixnum port))) (if (= v 2) g-stderr v)) g-stdout))
(define (b-write-char x)
  (let ((c (cell-car x)) (rest (cell-cdr x)))
    (emit (if (= (cell-type rest) TPAIR) (port-fd (cell-car rest)) g-stdout)
          (char-value c))
    c))
; open-output-file (posix.c): O_WRONLY|O_CREAT|O_TRUNC (577), mode 0644 (420);
; the fd IS the output port (port-fd maps a TNUMBER port -> its fd).  Returns
; the number -1 on failure so the boot's (= port -1) check fires.  MesCC's
; with-output-to-file uses this + set-current-output-port to emit the .s.
(define (b-open-output-file fname)
  (let ((fd (sys-open (mes-string->rsc fname) 577 420)))
    (make-number-fx (if (< fd 0) -1 fd))))
; set-current-output-port (posix.c): retarget output to the port's fd; return
; the previous current-output-port (a TNUMBER fd) so with-output-to-port can
; restore it.  b-write-char / current-output-port both read g-stdout.
(define (b-set-current-output-port port)
  (let ((prev (make-number-fx g-stdout)))
    (if (= (cell-type port) TNUMBER) (set! g-stdout (num-fixnum port)) 'ok)
    prev))
; write-byte (posix.c): like write-char but the value is a byte (TNUMBER/TCHAR);
; both store the value in the cdr field, so num-fixnum reads it uniformly.
(define (b-write-byte x)
  (let ((c (cell-car x)) (rest (cell-cdr x)))
    (emit (if (= (cell-type rest) TPAIR) (port-fd (cell-car rest)) g-stdout)
          (num-fixnum c))
    c))

; --- D8 leaf helpers (lib.c / posix.c / string.c / struct.c) ---
(define (reverse-x- x tail)                    ; core:reverse! (destructive)
  (if (= x cell-nil) tail
      (let ((next (cell-cdr x))) (set-cdr! x tail) (reverse-x- next x))))
(define (append-reverse- x tail)               ; append-reverse (non-destructive)
  (if (= x cell-nil) tail
      (append-reverse- (cell-cdr x) (qcons (cell-car x) tail))))
(define (b-getenv s)
  (let ((v (getenv (mes-string->rsc s))))
    (if v (string-rsc v) cell-f)))
(define (b-string->symbol s)                   ; intern the string's bytes
  (let ((start byte-free)) (sa-copy s) (intern start (- byte-free start))))
(define (b-make-symbol s)                      ; uninterned symbol (make_symbol)
  (retag TSYMBOL s))
(define (last-pair- x)
  (if (and (= (cell-type x) TPAIR) (= (cell-type (cell-cdr x)) TPAIR))
      (last-pair- (cell-cdr x)) x))
(define (b-make-hash-table x)                  ; arity n: optional size
  (if (= (cell-type x) TPAIR) (make-hash-table- (num-fixnum (cell-car x)))
      (make-hash-table- 0)))
(define (b-make-vector x)                       ; arity n: k [fill]
  (let ((k (num-fixnum (cell-car x)))
        (fill (if (= (cell-type (cell-cdr x)) TPAIR) (cell-car (cell-cdr x)) cell-unspec)))
    (make-vector- k fill)))

; ===========================================================================
; apply_builtin — leaf dispatch on the builtin id (eval-apply.c:382 adapted)
; ===========================================================================
; The dispatch is split into small chained cond blocks: the qfasm assembler
; recurses over each top-level form on the host stack, so one 60-deep nested
; `if` would overflow it.  Keep each sub-dispatcher shallow.
; apply_builtin (eval-apply.c:381-400): before dispatching, a TVALUES in the
; first (and, for arity>1/-1, second) argument position is coerced to its first
; value — this is how `(values v ...)` passes a single value through to a
; builtin (e.g. call-cc.scm's `(core:display (values 'foobar global))`).
(define (apply-builtin fn x)
  (let ((arity (num-fixnum (builtin-arity- fn))))
    (if (and (or (> arity 0) (= arity -1)) (not (= x cell-nil))
             (= (cell-type (cell-car x)) TVALUES))
        (set! x (qcons (cell-car (cell-cdr (cell-car x))) (cell-cdr x)))
        'ok)
    (if (and (or (> arity 1) (= arity -1)) (not (= x cell-nil))
             (= (cell-type (cell-cdr x)) TPAIR)
             (= (cell-type (cell-car (cell-cdr x))) TVALUES))
        (set! x (qcons (cell-car x)
                       (qcons (cell-car (cell-cdr (cell-car (cell-cdr x))))
                              (cell-cdr x))))
        'ok)
    (apply-builtin-core (builtin-id fn) x)))
(define (apply-builtin-core id x)
  (cond
    ((= id ID-CONS) (qcons (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-CAR) (cell-car (cell-car x)))
    ((= id ID-CDR) (cell-cdr (cell-car x)))
    ((= id ID-LIST) x)
    ((= id ID-EXIT) (b-exit x))
    ((= id ID-NULLP) (if (= (cell-car x) cell-nil) cell-t cell-f))
    ((= id ID-PAIRP) (if (= (cell-type (cell-car x)) TPAIR) cell-t cell-f))
    ((= id ID-EQP) (eq-p (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-DISPLAY) (begin (display- (cell-car x) 1 0) cell-unspec))
    ((= id ID-WRITE) (begin (display- (cell-car x) 1 1) cell-unspec))
    ((= id ID-DISPLAY-ERR) (begin (display- (cell-car x) 2 0) cell-unspec))
    ((= id ID-WRITE-ERR) (begin (display- (cell-car x) 2 1) cell-unspec))
    ((= id ID-SETCAR) (begin (set-car! (cell-car x) (cell-car (cell-cdr x))) cell-unspec))
    ((= id ID-SETCDR) (begin (set-cdr! (cell-car x) (cell-car (cell-cdr x))) cell-unspec))
    ((= id ID-CURRENT-MODULE) m1)
    ((= id ID-LENGTH) (make-number-fx (length- (cell-car x))))
    ((= id ID-MEMQ) (memq- (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-EQUAL2) (equal2- (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-STRINGEQ) (string-eq-p (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-STRING-APPEND) (string-append- x))
    ((= id ID-STRING-LENGTH) (make-number-fx (strlike-len (cell-car x))))
    ((= id ID-STRING-REF) (b-string-ref (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-STRING-SET)
     (b-string-set (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    (else (apply-builtin-math id x))))
(define (apply-builtin-math id x)
  (cond
    ((= id ID-PLUS) (b-plus x))
    ((= id ID-MINUS) (b-minus x))
    ((= id ID-IS) (b-is x))
    ((= id ID-MULT) (b-mult x))
    ((= id ID-DIV) (b-div x))
    ((= id ID-LESS) (b-less x))
    ((= id ID-GREATER) (b-greater x))
    ((= id ID-MODULO) (b-modulo (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-ASH) (b-ash (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-LOGAND) (b-logand x))
    ((= id ID-LOGIOR) (b-logior x))
    ((= id ID-LOGXOR) (b-logxor x))
    ((= id ID-LOGNOT) (b-lognot x))
    ((= id ID-ERROR) (b-error (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-CORE-TYPE) (make-number-fx (cell-type (cell-car x))))
    ((= id ID-APPEND2) (append2 (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-VECTOR-LIST) (vector->list- (cell-car x)))
    ((= id ID-STRING-LIST) (string->list- (cell-car x)))
    ((= id ID-LIST-STRING) (list->string- (cell-car x)))
    ((= id ID-SYM-KEYWORD) (retag TKEYWORD (cell-car x)))
    ((= id ID-KEYWORD-STRING) (retag TSTRING (cell-car x)))
    (else (apply-builtin-port id x))))
(define (apply-builtin-port id x)
  (cond
    ((= id ID-OPEN-INPUT-STRING) (b-open-input-string (cell-car x)))
    ((= id ID-CURRENT-INPUT-PORT) (b-current-input-port))
    ((= id ID-SET-CURRENT-INPUT-PORT) (b-set-current-input-port (cell-car x)))
    ((= id ID-READ-STRING) (b-read-string x))
    ((= id ID-CURRENT-OUTPUT-PORT) (make-number-fx g-stdout))
    ((= id ID-WRITE-CHAR) (b-write-char x))
    ((= id ID-WRITE-BYTE) (b-write-byte x))
    ((= id ID-READ-BYTE) (make-number-fx (getchar-)))
    ((= id ID-PEEK-BYTE) (make-number-fx (peekchar)))
    ((= id ID-UNREAD-BYTE) (begin (unreadchar (num-fixnum (cell-car x))) (cell-car x)))
    ((= id ID-DISPLAY-PORT) (begin (display- (cell-car x) (port-fd (cell-car (cell-cdr x))) 0) cell-unspec))
    ((= id ID-WRITE-PORT) (begin (display- (cell-car x) (port-fd (cell-car (cell-cdr x))) 1) cell-unspec))
    ((= id ID-CURRENT-ERROR-PORT) (make-number-fx g-stderr))
    (else (apply-builtin-more id x))))
(define (apply-builtin-more id x)
  (cond
    ((= id ID-CORE-HASHQ-REF)
     (hashq-ref- (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-HASHQ-GET-HANDLE) (hashq-get-handle (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-HASHQ-SET) (hashq-set-x (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-MAKE-HASH-TABLE) (b-make-hash-table x))
    ((= id ID-HASH-TABLEP) (hash-table-p (cell-car x)))
    ((= id ID-HASH-SET) (hash-set-x (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-CORE-HASH-REF) (hash-ref- (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-HASH-REMOVE) (hash-remove-x (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-HASH-CLEAR) (hash-clear-x (cell-car x)))
    ((= id ID-HASH-BUCKETS) (ht-buckets (cell-car x)))
    ((= id ID-HASH-CREATE-HANDLE) (hash-create-handle-x (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-HASHQ-CREATE-HANDLE) (hashq-create-handle-x (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-SET-CURRENT-MODULE) (b-set-current-module (cell-car x)))
    ((= id ID-MAKE-BINDING) (make-binding- (qcons (cell-car x) (cell-car (cell-cdr x))) 0))
    ((= id ID-INITIAL-MODULE) m0)
    ((= id ID-CORE-REVERSE) (reverse-x- (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-APPEND-REVERSE) (append-reverse- (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-GETENV) (b-getenv (cell-car x)))
    ((= id ID-CHAR-INT) (make-number-fx (char-value (cell-car x))))
    ((= id ID-INT-CHAR) (make-char (num-fixnum (cell-car x))))
    ((= id ID-STRING-SYMBOL) (b-string->symbol (cell-car x)))
    ((= id ID-SYMBOL-STRING) (retag TSTRING (cell-car x)))
    ((= id ID-MAKE-SYMBOL) (b-make-symbol (cell-car x)))
    ((= id ID-CORE-CAR) (b-core-car (cell-car x)))
    ((= id ID-CORE-CDR) (b-core-cdr (cell-car x)))
    ((= id ID-ACONS) (acons (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-ASSQ) (qassq (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-ASSOC) (assoc- (cell-car x) (cell-car (cell-cdr x))))
    ((= id ID-OPEN-OUTPUT-FILE) (b-open-output-file (cell-car x)))
    ((= id ID-SET-CURRENT-OUTPUT-PORT) (b-set-current-output-port (cell-car x)))
    ((= id ID-LAST-PAIR) (last-pair- (cell-car x)))
    (else (apply-builtin-more2 id x))))
(define (apply-builtin-more2 id x)
  (cond
    ((= id ID-BUILTINP) (builtin-p (cell-car x)))
    ((= id ID-BUILTIN-NAME) (builtin-name- (cell-car x)))
    ((= id ID-BUILTIN-ARITY) (builtin-arity- (cell-car x)))
    ((= id ID-BUILTIN-PRINTER) (begin (builtin-printer g-stdout (cell-car x)) cell-unspec))
    ((= id ID-MAKE-VARIABLE) (make-variable (cell-car x)))
    ((= id ID-VARIABLEP) (variable-p (cell-car x)))
    ((= id ID-VARIABLE-REF) (variable-ref (cell-car x)))
    ((= id ID-VARIABLE-SET) (begin (variable-set-x (cell-car x) (cell-car (cell-cdr x))) cell-unspec))
    ((= id ID-MAKE-STRUCT) (make-struct (cell-car x) (cell-car (cell-cdr x)) (cell-car (cell-cdr (cell-cdr x)))))
    ((= id ID-STRUCT-LENGTH) (make-number-fx (cell-car (cell-car x))))
    ((= id ID-STRUCT-REF) (struct-ref- (cell-car x) (num-fixnum (cell-car (cell-cdr x)))))
    ((= id ID-STRUCT-SET) (begin (struct-set-x- (cell-car x) (num-fixnum (cell-car (cell-cdr x))) (cell-car (cell-cdr (cell-cdr x)))) cell-unspec))
    ((= id ID-LIST-VECTOR) (list->vector- (cell-car x)))
    ((= id ID-VECTORP) (if (= (cell-type (cell-car x)) TVECTOR) cell-t cell-f))
    ((= id ID-VECTOR-LENGTH) (make-number-fx (vector-length- (cell-car x))))
    ((= id ID-VECTOR-REF) (vector-ref- (cell-car x) (num-fixnum (cell-car (cell-cdr x)))))
    ((= id ID-VECTOR-SET) (begin (vector-set-x- (cell-car x) (num-fixnum (cell-car (cell-cdr x))) (cell-car (cell-cdr (cell-cdr x)))) cell-unspec))
    ((= id ID-MAKE-VECTOR) (b-make-vector x))
    (else (apply-builtin-io id x))))
(define (apply-builtin-io id x)
  (cond
    ((= id ID-PRIMITIVE-LOAD) (b-primitive-load (cell-car x)))
    ((= id ID-OPEN-INPUT-FILE) (b-open-input-file (cell-car x)))
    ((= id ID-ACCESS) (b-access (cell-car x)))
    ; isatty? (posix.c): no ioctl primitive in the rsc runtime; under the
    ; reference harness every fd is redirected (non-tty), so isatty? is #f.
    ((= id ID-ISATTY) cell-f)
    ((= id ID-READ-CHAR) (b-read-char))
    ((= id ID-PEEK-CHAR) (b-peek-char))
    ((= id ID-READ-INPUT-FILE-ENV) (read-all-forms))
    ((= id ID-GC) (qgc))
    ((= id ID-GC-STATS) (b-gc-stats))
    ((= id ID-GC-CHECK) (gc-check))
    ((= id ID-VALUES) (b-values x))
    ((= id ID-MAKE-STACK) (b-make-stack))
    ((= id ID-STACK-LENGTH) (b-stack-length (cell-car x)))
    ((= id ID-STACK-REF) (b-stack-ref (cell-car x) (cell-car (cell-cdr x))))
    (else
     (if (= qmes-debug-err 0) 'ok
         (begin (emit-str g-stderr ";;; qmes-unknown-builtin-id ")
                (emit-number g-stderr id) (emit g-stderr 10)))
     (qfail))))

(define (b-exit x)
  (if (= qmes-debug-err 0) 'ok
      (begin (emit-str g-stderr ";;; qmes gc-count=") (emit-number g-stderr gc-count)
             (emit g-stderr 10)))
  (if (= x cell-nil) (exit 0) (exit (num-fixnum (cell-car x)))))

; ===========================================================================
; main / boot loading (src/mes.c open_boot).
; ===========================================================================
(define g-chunk (make-string 65536))

; slurp an fd into the byte pool, returning a TSTRING over the bytes read.
(define (slurp-file-to-pool fd)
  (let ((start byte-free))
    (slurp-pool-loop fd)
    (make-strlike TSTRING start (- byte-free start))))
(define (slurp-pool-loop fd)
  (let ((n (sys-read fd g-chunk)))
    (if (> n 0) (begin (pool-append-chunk n 0) (slurp-pool-loop fd)) 'done)))
(define (pool-append-chunk n i)
  (if (< i n) (begin (bytes-put! (string-ref g-chunk i)) (pool-append-chunk n (+ i 1))) 'ok))
; Read an fd into a fresh string input port and make it current.
(define (fd->current-input-port! fd)
  (let ((strcell (slurp-file-to-pool fd)))
    (sys-close fd)
    (b-set-current-input-port (b-open-input-string strcell))))

; open_boot (mes.c:127-176): search order sets g-datadir as a side effect so
; %datadir/%moduledir resolve.  MES_PREFIX/mes/module/mes/<boot> first, then
; MES_PREFIX/share/mes, then srcdest ("mes"), then <boot> directly.
(define g-datadir ".")
(define (try-boot datadir boot)
  (set! g-datadir datadir)
  (sys-open (string-append datadir "/module/mes/" boot) 0 0))
(define (open-boot)
  (let ((boot (let ((mb (getenv "MES_BOOT"))) (if mb mb "boot-5.scm")))
        (pfx (getenv "MES_PREFIX")))
    (set! g-datadir ".")
    (if pfx
        (let ((fd (try-boot (string-append pfx "/mes") boot)))
          (if (>= fd 0) fd
              (let ((fd2 (try-boot (string-append pfx "/share/mes") boot)))
                (if (>= fd2 0) fd2 (open-boot-tail boot)))))
        (open-boot-tail boot))))
(define (open-boot-tail boot)
  (set! g-datadir "mes")                    ; srcdest unset -> "mes"
  (let ((fd (sys-open (string-append "mes/module/mes/" boot) 0 0)))
    (if (>= fd 0) fd (sys-open boot 0 0))))  ; <boot> direct; g-datadir stays "mes"

(define floor 0)

; read_input_file_env (reader.c:38): read forms until a top-level cell-nil
; (EOF or `)`), resetting the reader pushback for a fresh port.
;
; Chunked host-heap reclamation (mirrors the GC loops, §2.4, and asm.scm's
; slurp-loop): reading a whole file (e.g. nyacc's 100 KiB c99-tab.scm) conses
; megabytes of transient host (rsc) frames.  If those accumulate across the
; forms of a file — and across the nested primitive-load chain — the 512 MiB
; host pair heap overflows into g-cells and silently smashes the low cells
; (docs/qmes-define-module-diagnosis.md).  So read-forms-loop is a NILADIC
; self-tail loop with all surviving state in globals (rd-forms is a g-cells
; list index — immediate; the parsed datum lives in g-cells), and the host
; heap is reset to a floor captured at read-all-forms entry (mark+64) once per
; top-level form.  The loop's single migrating frame lands in the +64 pad; the
; forms already read survive because they are g-cells structures.
(define rd-floor #f)                            ; host-heap floor for reader resets
(define rd-forms 0)                             ; forms read so far, reversed (g-cells)
(define (read-all-forms)
  (set! rd-pb -2)
  (set! rd-forms cell-nil)
  (set! rd-floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
  (read-forms-loop))
(define (read-forms-loop)
  (host-heap-reset! rd-floor)                   ; reclaim prior form's reader transients
  (host-heap-guard!)                            ; tripwire: fail clean before overflow
  (let ((form (reader-read-sexp (getchar-))))
    (if (= form cell-nil)
        (reverse-x- rd-forms cell-nil)          ; restore source order (destructive, tail)
        (begin (set! rd-forms (qcons form rd-forms))
               (read-forms-loop)))))

; ===========================================================================
; The VM dispatcher (eval-apply.c:442-504) and the state machine.
; The host-heap safepoint runs first, once per dispatch (design §4).
; Every st-* procedure is only ever tail-called (design §4.4).
; ===========================================================================
(define qmes-no-reset 0)             ; bisect switch (design §4.3.4)

; --- nested trampoline / floor stack (FD §4) -------------------------------
; vm-run-nested is the ONLY way to re-enter the VM (primitive-load, and later
; error->throw / eval-closures / struct printers).  It pushes a new floor
; (mark+64) so the nested run's dispatch resets reclaim only what the nested
; run allocates; the outer builtin's rsc frames were allocated below this mark
; and are protected.  On return it pops the floor.  All Mes VM state lives in
; g-cells/g-stack (never host-reset), so only rsc host frames are at stake, and
; this let-frame (holding the saved floor) is itself below the nested floor.
; Audit: floor is captured BEFORE the mark; the new floor > this frame > the
; mark boxes (protected by the +64 pad); no host value crosses into a global.
(define (vm-run-nested)
  (host-heap-guard!)                             ; tripwire before each VM re-entry
  (let ((saved-floor floor))
    (set! floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
    (let ((result (vm-dispatch)))
      (set! floor saved-floor)
      result)))

; primitive_load (eval-apply.c:1039-1071): set current input to the file, read
; all forms into (begin . forms), restore the port, then eval via the nested
; trampoline with a sentinel frame.
; Capture the host-heap mark BEFORE the read so the read's transients (and the
; slurp of the file into the byte pool) are reclaimed before the nested eval
; captures its floor — otherwise every deeper load's floor ratchets upward on
; top of this file's read garbage and the pair heap never gets reclaimed until
; the outermost dispatch (docs/qmes-define-module-diagnosis.md §4.1(2)).  forms
; and input are g-cells / immediate, so the reset to mark+64 keeps them.
(define (b-primitive-load fname)
  (let ((mark (host-heap-mark))
        (input (b-set-current-input-port (primitive-load-port fname))))
    (let ((forms (qcons cell-symbol-begin (read-all-forms))))
      (b-set-current-input-port input)
      (host-heap-reset! (w32-add mark (w32-from-fixnum 64)))
      (primitive-load-eval forms))))
(define (primitive-load-port fname)
  (cond ((and (= (cell-type fname) TNUMBER) (= (num-fixnum fname) 0)) (b-current-input-port))
        ((= (cell-type fname) TSTRING) (b-open-input-file fname))
        ((= (cell-type fname) TPORT) fname)
        (else (qfail))))
(define (primitive-load-eval forms)
  (let ((env (acons cell-symbol-program forms cell-nil)))
    (push-frame!)                              ; gc_push_frame (save outer r0-r3)
    (push-cc! forms cell-unspec env cell-unspec) ; sentinel frame (r3=cell-unspec)
    (set! r3 cell-vm-begin-expand)
    (let ((result (vm-run-nested)))            ; nested eval_apply
      (pop-frame!)                             ; gc_pop_frame (restore outer r0-r3)
      result)))
; apply (eval-apply.c:1030-1036): re-enter the VM to apply f to the argument
; list x in environment a, via the nested trampoline (FD §4 error->throw path).
(define (apply-proc f args a)
  (push-frame!)
  (push-cc! (qcons f args) cell-unspec a cell-unspec)  ; sentinel (r3=unspec)
  (set! r3 cell-vm-apply)
  (let ((result (vm-run-nested)))
    (pop-frame!)
    result))

; error (core.c:150): if `throw` is bound, apply it to (key x); else print the
; error to stderr (display key / write x) and exit 1.  On the happy boot path
; this is only *referenced* (define core:error error), never called.
(define (b-error key x)
  (let ((throw (lookup-value cell-symbol-throw)))
    (if (not (= throw cell-undefined))
        (apply-proc throw (qcons key (qcons x cell-nil)) r0)
        (begin (display- key g-stderr 0) (emit-str g-stderr ": ")
               (display- x g-stderr 1) (emit g-stderr 10)
               (exit 1)))))

; access? (posix.c): probe readability by opening O_RDONLY (R_OK is the only
; mode the boot uses — search-path/file-exists?/include-from-path).
(define (b-access fname)
  (let ((fd (sys-open (mes-string->rsc fname) 0 0)))
    (if (< fd 0) cell-f (begin (sys-close fd) cell-t))))

; open_input_file: slurp the file into a string input port (observably a port).
(define (b-open-input-file fname)
  (let ((fd (sys-open (mes-string->rsc fname) 0 0)))
    (if (< fd 0)
        (qfail)
        (let ((strcell (slurp-file-to-pool fd)))
          (sys-close fd)
          (b-open-input-string strcell)))))
(define (b-read-char) (make-char (getchar-)))  ; D2: EOF = char -1
(define (b-peek-char) (make-char (peekchar)))

(define (vm-dispatch)
  (if (= qmes-no-reset 0) (host-heap-reset! floor) 'nop)
  (cond
    ((= r3 cell-vm-evlis2)                (st-evlis2))
    ((= r3 cell-vm-evlis3)                (st-evlis3))
    ((= r3 cell-vm-eval-check-func)       (st-eval-check-func))
    ((= r3 cell-vm-eval2)                 (st-eval2))
    ((= r3 cell-vm-apply2)                (st-apply2))
    ((= r3 cell-vm-call-with-current-continuation2) (st-cc2))
    ((= r3 cell-vm-call-with-values2)     (st-call-with-values2))
    ((= r3 cell-vm-if-expr)               (st-if-expr))
    ((= r3 cell-vm-begin-eval)            (st-begin-eval))
    ((= r3 cell-vm-eval-set-x)            (st-eval-set-x))
    ((= r3 cell-vm-macro-expand-car)      (st-macro-expand-car))
    ((= r3 cell-vm-return)                (st-vm-return))
    ((= r3 cell-vm-macro-expand-cdr)      (st-macro-expand-cdr))
    ((= r3 cell-vm-eval-define)           (st-eval-define))
    ((= r3 cell-vm-macro-expand)          (st-macro-expand))
    ((= r3 cell-vm-macro-expand-lambda)   (st-macro-expand-lambda))
    ((= r3 cell-vm-begin-expand-macro)    (st-begin-expand-macro))
    ((= r3 cell-vm-macro-expand-define)   (st-macro-expand-define))
    ((= r3 cell-vm-begin-expand-eval)     (st-begin-expand-eval))
    ((= r3 cell-vm-macro-expand-set-x)    (st-macro-expand-set-x))
    ((= r3 cell-vm-macro-expand-define-macro) (st-macro-expand-define-macro))
    ((= r3 cell-vm-evlis)                 (st-evlis))
    ((= r3 cell-vm-apply)                 (st-apply))
    ((= r3 cell-vm-eval)                  (st-eval))
    ((= r3 cell-vm-eval-macro-expand-eval)   (st-eval-macro-expand-eval))
    ((= r3 cell-vm-eval-macro-expand-expand) (st-eval-macro-expand-expand))
    ((= r3 cell-vm-begin)                 (st-begin))
    ((= r3 cell-vm-begin-expand)          (st-begin-expand))
    ((= r3 cell-vm-if)                    (st-vm-if))
    ((= r3 cell-unspec)                   r1)
    (else (qfail))))

(define (st-vm-return)
  (let ((x r1))
    (pop-frame!)
    (set! r1 x))
  (vm-dispatch))

; --- evlis (C 506-518) ---
(define (st-evlis)
  (cond ((= r1 cell-nil) (st-vm-return))
        ((not (= (cell-type r1) TPAIR)) (st-eval))
        (else (begin (push-cc! (cell-car r1) r1 r0 cell-vm-evlis2) (st-eval)))))
(define (st-evlis2)
  (push-cc! (cell-cdr r2) r1 r0 cell-vm-evlis3)
  (st-evlis))
(define (st-evlis3)
  (set! r1 (qcons r2 r1))
  (st-vm-return))

; --- apply (C 520-614) ---
(define (st-apply)
  (stack-set! (+ stkp 4) (cell-car r1))
  (let* ((f (cell-car r1)) (t (cell-type f)))
    (cond
      ((and (= t TSTRUCT) (= (builtin-p f) cell-t))
       (begin
         (check-formals f (builtin-arity- f) (cell-cdr r1))
         (set! r1 (apply-builtin f (cell-cdr r1)))
         (st-vm-return)))
      ((= t TCLOSURE) (st-apply-closure f))
      ((= t TCONTINUATION) (st-apply-continuation f))
      ((= t TSPECIAL) (st-apply-special f))
      ((= t TSYMBOL) (st-apply-symbol f))
      ((= t TPAIR) (st-apply-pair f))
      (else (st-apply-fallthrough)))))
(define (st-apply-closure f)
  (let* ((cl (cell-cdr f))
         (body (cell-cdr (cell-cdr cl)))
         (formals (cell-car (cell-cdr cl)))
         (args (cell-cdr r1))
         (aa (cell-cdr (cell-cdr (cell-car cl)))))
    (check-formals (cell-car r1) formals (cell-cdr r1))
    (let ((p (pairlis formals args aa)))
      (set! r1 body)
      (set! r0 (qcons (qcons cell-closure p) p))
      (st-begin))))
(define (st-apply-special f)
  (cond
    ((= f cell-vm-apply)
     (begin
       (push-cc! (qcons (cell-car (cell-cdr r1)) (cell-car (cell-cdr (cell-cdr r1))))
                 r1 r0 cell-vm-return)
       (st-apply)))
    ((= f cell-vm-eval)
     (begin
       (push-cc! (cell-car (cell-cdr r1)) r1 (cell-car (cell-cdr (cell-cdr r1)))
                 cell-vm-return)
       (st-eval)))
    ((= f cell-vm-begin-expand)
     (begin
       (push-cc! (qcons (cell-car (cell-cdr r1)) cell-nil)
                 r1 (cell-car (cell-cdr (cell-cdr r1))) cell-vm-return)
       (st-begin-expand)))
    (else (begin (check-apply cell-f f) (st-apply-fallthrough)))))
(define (st-apply-symbol f)
  (cond
    ((= f cell-symbol-call-with-current-continuation)
     (begin (set! r1 (cell-cdr r1)) (st-call-with-current-continuation)))
    ((= f cell-symbol-call-with-values)
     (begin (set! r1 (cell-cdr r1)) (st-call-with-values)))
    ((= f cell-symbol-current-environment) (begin (set! r1 r0) (st-vm-return)))
    (else (st-apply-fallthrough))))

; --- restore (eval-apply.c:543-555): reinstate the saved stack, single value.
(define (st-apply-continuation f)
  (let* ((v (cell-cdr f))
         (len (vector-length- v)))
    (if (not (= len 0))
        (begin (restore-stack v len 0) (set! stkp (- STACK-SIZE len)))
        'ok)
    (set! r1 (cell-car (cell-cdr r1)))
    (st-vm-return)))

; --- capture (eval-apply.c:996-1010): the double snapshot (§3.1 item 1).  R2 =
; the continuation x roots the in-progress snapshot across the applied thunk.
(define (st-call-with-current-continuation)
  (let ((x (make-continuation g-continuations)))
    (set! g-continuations (+ g-continuations 1))
    (set-cdr! x (snapshot-stack))              ; x->continuation = v
    (push-cc! (qcons (cell-car r1) (qcons x cell-nil)) x r0
              cell-vm-call-with-current-continuation2)
    (st-apply)))
(define (st-cc2)                               ; call_with_current_continuation2
  (set-cdr! r2 (snapshot-stack))               ; re-snapshot into R2->continuation
  (st-vm-return))

; --- call-with-values (eval-apply.c:1012-1021): apply consumer to the values.
(define (st-call-with-values)
  (push-cc! (qcons (cell-car r1) cell-nil) r1 r0 cell-vm-call-with-values2)
  (st-apply))
(define (st-call-with-values2)
  (if (= (cell-type r1) TVALUES)
      (set! r1 (cell-cdr r1))
      (set! r1 (qcons r1 cell-nil)))
  (set! r1 (qcons (cell-car (cell-cdr r2)) r1))
  (st-apply))
(define (st-apply-pair f)
  (if (= (cell-car f) cell-symbol-lambda)
      (let* ((formals (cell-car (cell-cdr f)))
             (args (cell-cdr r1))
             (body (cell-cdr (cell-cdr f)))
             (p (pairlis formals (cell-cdr r1) r0)))
        (check-formals r1 formals args)
        (set! r1 body)
        (set! r0 (qcons (qcons cell-closure p) p))
        (st-begin))
      (st-apply-fallthrough)))
(define (st-apply-fallthrough)
  (push-cc! (cell-car r1) r1 r0 cell-vm-apply2)
  (st-eval))
(define (st-apply2)
  (check-apply r1 (cell-car r2))
  (set! r1 (qcons r1 (cell-cdr r2)))
  (st-apply))

; --- eval (C 616-802) ---
(define (st-eval)
  (let ((t (cell-type r1)))
    (cond
      ((= t TPAIR) (st-eval-pair))
      ((= t TSYMBOL) (st-eval-symbol))
      ((= t TBINDING) (st-eval-binding))
      ((= t TBROKEN-HEART) (qfail))
      (else (st-vm-return)))))
(define (st-eval-pair)
  (let ((c0 (cell-car r1)))
    (if (= (cell-type c0) TBINDING)
        (begin
          (if (not (= (binding-lexical-p c0) 0))
              (set-car! r1 (cell-cdr (binding-handle c0)))
              (set-car! r1 (variable-ref (cell-cdr (binding-handle c0)))))
          (if (= (cell-car r1) cell-undefined)
              (begin (qerror-diag "head-undefined" (cell-car (binding-handle c0)))
                     (qfail))))
        'ok))
  (let ((c (cell-car r1)))
    (cond
      ((= c cell-symbol-quote)
       (begin (set! r1 (cell-car (cell-cdr r1))) (st-vm-return)))
      ((= c cell-symbol-begin) (st-begin))
      ((= c cell-symbol-lambda)
       (begin (set! r1 (make-closure- (cell-car (cell-cdr r1))
                                      (cell-cdr (cell-cdr r1)) r0))
              (st-vm-return)))
      ((= c cell-symbol-if) (begin (set! r1 (cell-cdr r1)) (st-vm-if)))
      ((= c cell-symbol-set-x)
       (begin (push-cc! (cell-car (cell-cdr (cell-cdr r1))) r1 r0 cell-vm-eval-set-x)
              (st-eval)))
      ((= c cell-vm-macro-expand)
       (begin (push-cc! (cell-car (cell-cdr r1)) r1 r0 cell-vm-eval-macro-expand-eval)
              (st-eval)))
      ((or (= c cell-symbol-define) (= c cell-symbol-define-macro))
       (st-eval-define-entry))
      (else
       (begin (push-cc! (cell-car r1) r1 r0 cell-vm-eval-check-func)
              (gc-check)                         ; eval-apply.c:764
              (st-eval))))))
(define (st-eval-symbol)
  (cond
    ((= r1 cell-symbol-current-environment) (st-vm-return))
    ((= r1 cell-symbol-begin) (st-vm-return))
    ((= r1 cell-symbol-call-with-current-continuation) (st-vm-return))
    (else
     (begin (set! r1 (assert-defined r1 (lookup-value r1))) (st-vm-return)))))
(define (st-eval-binding)
  (let ((name (cell-car (binding-handle r1))))
    (if (not (= (binding-lexical-p r1) 0))
        (set! r1 (cell-cdr (binding-handle r1)))
        (set! r1 (variable-ref (cell-cdr (binding-handle r1)))))
    (if (= r1 cell-undefined) (qerror-unbound name) 'ok))
  (st-vm-return))
(define (st-eval-set-x)
  (set! r1 (set-x (cell-car (cell-cdr r2)) r1 0))
  (st-vm-return))
(define (st-eval-check-func)
  (push-cc! (cell-cdr r2) r2 r0 cell-vm-eval2)
  (st-evlis))
(define (st-eval2)
  (set! r1 (qcons (cell-car r2) r1))
  (st-apply))
(define (st-eval-macro-expand-eval)
  (push-cc! r1 r2 r0 cell-vm-eval-macro-expand-expand)
  (st-macro-expand))
(define (st-eval-macro-expand-expand) (st-vm-return))

; --- eval_define entry + continuation (C 673-761, §3.4) ---
(define (st-eval-define-entry)
  (let ((global-p (if (= (cell-car (cell-car r0)) cell-closure) 0 1))
        (macro-p (if (= (cell-car r1) cell-symbol-define-macro) 1 0)))
    (if (= global-p 1)
        (let* ((name0 (cell-car (cell-cdr r1)))
               (name (if (= (cell-type name0) TPAIR) (cell-car name0) name0)))
          (if (= macro-p 1)
              (let ((entry (macro-get-handle name)))
                (if (= entry cell-f) (macro-set-x name cell-f) 'ok))
              (lookup-binding name cell-t)))
        'ok)
    (set! r2 r1)
    (let ((aa (cell-car (cell-cdr r1))))
      (if (not (= (cell-type aa) TPAIR))
          (begin
            (push-cc! (cell-car (cell-cdr (cell-cdr r1))) r2
                      (qcons (qcons (cell-car (cell-cdr r1)) (cell-car (cell-cdr r1))) r0)
                      cell-vm-eval-define)
            (st-eval))
          (let ((formals (cell-cdr (cell-car (cell-cdr r1))))
                (body (cell-cdr (cell-cdr r1))))
            (if (or (= macro-p 1) (= global-p 1))
                (expand-variable body formals) 'ok)
            (let ((p (pairlis (cell-car (cell-cdr r1)) (cell-car (cell-cdr r1)) r0)))
              (set! r1 (qcons cell-symbol-lambda
                              (qcons (cell-cdr (cell-car (cell-cdr r1)))
                                     (cell-cdr (cell-cdr r1)))))
              (push-cc! r1 r2 p cell-vm-eval-define)
              (st-eval)))))))
(define (st-eval-define)
  (let* ((global-p (if (= (cell-car (cell-car r0)) cell-closure) 0 1))
         (macro-p (if (= (cell-car r2) cell-symbol-define-macro) 1 0))
         (name0 (cell-car (cell-cdr r2)))
         (name (if (= (cell-type name0) TPAIR) (cell-car name0) name0)))
    (cond
      ((= macro-p 1)
       (let ((entry (macro-get-handle name)))
         (set! r1 (make-macro name r1))
         (set-cdr! entry r1)))
      ((= global-p 1) (set-x name r1 1))
      (else
       (let* ((entry (qcons name r1))
              (aa (qcons entry cell-nil)))
         (set-cdr! aa (cell-cdr r0))
         (set-cdr! r0 aa)
         (set-cdr! (cell-car r0) aa))))
    (set! r1 cell-unspec)
    (st-vm-return)))

; --- macro_expand family (C 804-892) ---
(define (st-macro-expand)
  (if (or (not (= (cell-type r1) TPAIR)) (= (cell-car r1) cell-symbol-quote))
      (st-vm-return)
      (macro-expand-dispatch)))
(define (macro-expand-dispatch)
  (let ((c (cell-car r1)))
    (cond
      ((= c cell-symbol-lambda)
       (begin (push-cc! (cell-cdr (cell-cdr r1)) r1 r0 cell-vm-macro-expand-lambda)
              (st-macro-expand)))
      ((or (= c cell-symbol-define) (= c cell-symbol-define-macro))
       (begin (push-cc! (cell-cdr (cell-cdr r1)) r1 r0 cell-vm-macro-expand-define)
              (st-macro-expand)))
      ((= c cell-symbol-set-x)
       (begin (push-cc! (cell-cdr (cell-cdr r1)) r1 r0 cell-vm-macro-expand-set-x)
              (st-macro-expand)))
      (else (macro-expand-general)))))
(define (macro-expand-general)
  (let ((macro (get-macro (cell-car r1))))
    (if (not (= macro cell-f))
        (begin
          (set! r1 (qcons macro (cell-cdr r1)))
          (push-cc! r1 cell-nil r0 cell-vm-macro-expand)
          (st-apply))
        (begin
          (push-cc! (cell-car r1) r1 r0 cell-vm-macro-expand-car)
          (st-macro-expand)))))
(define (st-macro-expand-lambda)
  (set-cdr! (cell-cdr r2) r1)
  (set! r1 r2)
  (st-vm-return))
(define (st-macro-expand-define)
  (set-cdr! (cell-cdr r2) r1)
  (set! r1 r2)
  (if (= (cell-car r1) cell-symbol-define-macro)
      (begin (push-cc! r1 r1 r0 cell-vm-macro-expand-define-macro) (st-eval))
      (st-vm-return)))
(define (st-macro-expand-define-macro)
  (set! r1 r2)
  (st-vm-return))
(define (st-macro-expand-set-x)
  (set-cdr! (cell-cdr r2) r1)
  (set! r1 r2)
  (st-vm-return))
(define (st-macro-expand-car)
  (set-car! r2 r1)
  (set! r1 r2)
  (if (= (cell-cdr r1) cell-nil)
      (st-vm-return)
      (begin (push-cc! (cell-cdr r1) r1 r0 cell-vm-macro-expand-cdr)
             (st-macro-expand))))
(define (st-macro-expand-cdr)
  (set-cdr! r2 r1)
  (set! r1 r2)
  (st-vm-return))

; --- begin / begin_eval (C 894-920, §5.7) ---
(define (st-begin) (begin-loop cell-unspec))
(define (st-begin-eval)
  (let ((x r1))
    (set! r1 (cell-cdr r2))
    (begin-loop x)))
(define (begin-loop x)
  (if (= r1 cell-nil)
      (begin (set! r1 x) (st-vm-return))
      (begin
        (gc-check)                               ; eval-apply.c:898
        (if (and (= (cell-type r1) TPAIR)
                 (= (cell-type (cell-car r1)) TPAIR)
                 (= (cell-car (cell-car r1)) cell-symbol-begin))
            (set! r1 (append2 (cell-cdr (cell-car r1)) (cell-cdr r1))) 'ok)
        (if (= (cell-cdr r1) cell-nil)
            (begin (set! r1 (cell-car r1)) (st-eval))
            (begin (push-cc! (cell-car r1) r1 r0 cell-vm-begin-eval) (st-eval))))))

; --- begin_expand (C 923-975, §5.8) — the top-level driver ---
(define (st-begin-expand) (begin-expand-loop cell-unspec))
(define (begin-expand-loop x)
  (if (= r1 cell-nil)
      (begin (set! r1 x) (st-vm-return))
      (begin-expand-body)))
(define (begin-expand-body)
  (gc-check)                                     ; eval-apply.c:928 (begin_expand_while)
  (if (and (= (cell-type r1) TPAIR)
           (= (cell-type (cell-car r1)) TPAIR)
           (= (cell-car (cell-car r1)) cell-symbol-begin))
      (set! r1 (append2 (cell-cdr (cell-car r1)) (cell-cdr r1))) 'ok)
  (push-cc! (cell-car r1) r1 r0 cell-vm-begin-expand-macro)
  (st-macro-expand))
(define (st-begin-expand-macro)
  (if (not (= r1 (cell-car r2)))
      (begin (set-car! r2 r1) (set! r1 r2) (begin-expand-body))
      (begin
        (set! r1 r2)
        (if (and (= (cell-type r1) TPAIR)
                 (= (cell-type (cell-car r1)) TPAIR)
                 (= (cell-car (cell-car r1)) cell-symbol-define))
            (if (and (= (cell-type (cell-cdr (cell-car r1))) TPAIR)
                     (= (cell-type (cell-car (cell-cdr (cell-car r1)))) TPAIR))
                (lookup-binding (cell-car (cell-car (cell-cdr (cell-car r1)))) cell-t)
                'ok)
            'ok)
        (expand-variable (cell-car r1) cell-nil)
        (push-cc! (cell-car r1) r1 r0 cell-vm-begin-expand-eval)
        (st-eval))))
(define (st-begin-expand-eval)
  (let ((x r1))
    (set! r1 (cell-cdr r2))
    (begin-expand-loop x)))

; --- if (C 977-994, §1.6) ---
(define (st-vm-if)
  (push-cc! (cell-car r1) r1 r0 cell-vm-if-expr)
  (st-eval))
(define (st-if-expr)
  (let ((x r1))
    (set! r1 r2)
    (cond
      ((not (= x cell-f))
       (begin (set! r1 (cell-car (cell-cdr r1))) (st-eval)))
      ((not (= (cell-cdr (cell-cdr r1)) cell-nil))
       (begin (set! r1 (cell-car (cell-cdr (cell-cdr r1)))) (st-eval)))
      (else (begin (set! r1 cell-unspec) (st-vm-return))))))

; ===========================================================================
; main / boot (mes.c:211-243, §6.3)
; ===========================================================================
; env-num (gc.c:67-87 atoi-style): parse a leading unsigned decimal, with an
; optional `eN` exponent (MES_ARENA=20e6); missing/blank -> dflt.
(define (env-num name dflt)
  (let ((s (getenv name)))
    (if (not s) dflt
        (let ((n (string-length s)))
          (if (= n 0) dflt (env-num-parse s 0 n 0))))))
(define (env-num-parse s i n acc)
  (if (>= i n) acc
      (let ((c (char->integer (string-ref s i))))
        (cond ((and (>= c 48) (<= c 57))
               (env-num-parse s (+ i 1) n (+ (* acc 10) (- c 48))))
              ((or (= c 101) (= c 69))              ; e / E exponent
               (env-num-scale acc (env-num-parse s (+ i 1) n 0)))
              (else acc)))))
(define (env-num-scale acc e) (if (= e 0) acc (env-num-scale (* acc 10) (- e 1))))

(define (qmain)
  (set! w32-0 (w32-from-fixnum 0))
  ; Host pair-heap ceiling: base + cap MiB (default 496; 16 MiB slack under the
  ; real 512 MiB span).  Captured before the bulk of startup interning so the
  ; ceiling stays safely under the true top-of-heap.
  (set! host-heap-base (host-heap-mark))
  (set! host-heap-ceiling
        (w32-add host-heap-base
                 (w32-shl (w32-from-fixnum (env-num "QMES_HOSTHEAP_CAP_MIB" 496)) 20)))
  (set! g-stdin 0)
  (set! g-stdout 1)
  (set! g-stderr 2)
  ; D6/S2: env-driven arena/stack/byte-pool, allocated below the host-heap
  ; floor.  The cell arena carries JAM-CELLS of slack above ARENA-CELLS for the
  ; copy-up news space (gc.c:89); the byte pool is doubled for two-space
  ; compaction (§2.3).  GC-SAFETY / JAM-CELLS track gc.c:74,78.
  (set! ARENA-CELLS (env-num "MES_ARENA" 1000000))
  (set! STACK-SIZE (env-num "MES_STACK" 100000))
  (set! JAM-CELLS (env-num "MES_JAM" (quotient ARENA-CELLS 10)))
  (set! cell-cap (+ ARENA-CELLS JAM-CELLS))
  (set! GC-SAFETY (quotient ARENA-CELLS 100))
  (set! qmes-gc-stress (env-num "MES_GC_STRESS" 0))
  (set! qmes-debug-err (env-num "QMES_DEBUG_ERR" 0))
  (set! qmes-no-reset (env-num "QMES_NO_RESET" 0))
  (set! g-cells (make-vector (* 3 (+ ARENA-CELLS JAM-CELLS)) 0))
  (set! g-stack (make-vector STACK-SIZE 0))
  (set! g-bytes-a (make-string BYTE-POOL))
  (set! g-bytes-b (make-string BYTE-POOL))
  (set! g-bytes g-bytes-a)
  (set! byte-free 0)
  (set! BYTE-POOL-HI (- BYTE-POOL (quotient BYTE-POOL 8)))
  (init-cells)
  (set! g-symbol-max cell-free)                  ; freeze the fixed region (§2.1)
  (set! g-ports cell-nil)
  ; open_boot BEFORE mes_environment so g-datadir feeds %datadir (mes.c order).
  (let ((fd (open-boot)))
    (init-builtins)
    (set! m0 (make-initial-module env-alist))
    (set! m1 cell-f)
    (set! g-macros-table (make-hash-table- 0))
    (if (< fd 0)
        (exit 1)
        (fd->current-input-port! fd)))          ; boot fd -> current input port
  (build-obarray!)                              ; D4: switch interning to g-symbols
  ; Drop the init-phase scratch lists: their pairs live above g-symbol-max but
  ; are not roots (the symbols they held are reachable via g-symbols / m0).
  ; Nil-ing them keeps them from being stale indices after the first GC.
  (set! sym-table cell-nil)
  (set! env-alist cell-nil)
  (set! stkp STACK-SIZE)
  (set! r3 (make-char 0))
  (let ((program (read-all-forms)))
    (set! r0 cell-nil)
    (set! r0 (acons cell-symbol-program program r0))
    (push-cc! program cell-unspec r0 cell-unspec)
    (set! r3 cell-vm-begin-expand)
    (set! floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
    (vm-dispatch))
  (exit 0))

