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
;   3i+1 (car), 3i+2 (cdr).  Allocation is a bump counter `cell-free`; qmes
;   never GCs (scaffold files fit the arena) — host-heap-reset! only reclaims
;   rsc-level calling-convention garbage, never arena cells.

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
    i))

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

; TCHAR cell: value (small fixnum, as w32) in cdr (offset 2); car=0.
(define (make-char n)
  (let ((i (alloc-n 1)))
    (raw-set! i 0 (w32-from-fixnum TCHAR))
    (raw-set! i 1 (w32-from-fixnum 0))
    (raw-set! i 2 (w32-from-fixnum n))
    i))
(define (char-value i) (w32->fixnum (raw-ref i 2)))

(define (make-ref x) (alloc TREF x 0))

; ===========================================================================
; Byte pool: symbol names and string contents (in rsc's byte arena)
; ===========================================================================
(define BYTE-POOL 16777216)                    ; 16 MiB; boot module files slurp here
(define g-bytes 0)                             ; allocated in qmain
(define byte-free 0)
(define (bytes-put! ch)
  (string-set! g-bytes byte-free ch)
  (set! byte-free (+ byte-free 1)))
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
(define cell-symbol-hashq-table 0)
(define cell-symbol-variable 0)
(define cell-symbol-program 0)
(define cell-symbol-portable-macro-expand 0)
(define cell-symbol-sc-expander-alist 0)
(define cell-symbol-macro-expand 0)

(define sym-table 0)         ; interning list of symbol cells

; D1/D3 real type structs (builtins.c / hash.c / variable.c).  Symbols:
(define cell-symbol-builtin 0)      ; '<builtin>  (struct[2] tag of a builtin)
(define cell-symbol-buckets 0)      ; 'buckets
(define cell-symbol-size 0)         ; 'size
(define builtin-printer-sym 0)      ; 'builtin-printer (a symbol used as printer)
(define variable-printer-sym 0)     ; 'variable-printer
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

; Intern a name whose bytes already occupy g-bytes[start, byte-free).
(define (intern start len)
  (let ((found (intern-scan sym-table start len)))
    (if found
        (begin (set! byte-free start) found)   ; drop the duplicate copy
        (let ((s (make-strlike TSYMBOL start len)))
          (set! sym-table (qcons s sym-table))
          s))))

(define (intern-rsc str)
  (let ((start byte-free))
    (copy-rsc-into-pool str)
    (intern start (- byte-free start))))

; A fresh TSPECIAL fixed cell carrying `name` as bytes.
(define (special-rsc str)
  (let ((start byte-free))
    (copy-rsc-into-pool str)
    (make-strlike TSPECIAL start (- byte-free start))))

; ===========================================================================
; List helpers (core.c length__, assq)
; ===========================================================================
(define (length- x) (length-loop x 0))
(define (length-loop x n)
  (cond ((= x cell-nil) n)
        ((not (= (cell-type x) TPAIR)) -1)
        (else (length-loop (cell-cdr x) (+ n 1)))))

; identity assq (Mes assq for TSYMBOL/TSPECIAL keys) -> the (key . val) pair or cell-f
(define (qassq x a)
  (if (not (= (cell-type a) TPAIR)) cell-f (qassq-loop x a)))
(define (qassq-loop x a)
  (cond ((= a cell-nil) cell-f)
        ((= (cell-car (cell-car a)) x) (cell-car a))
        (else (qassq-loop x (cell-cdr a)))))

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
          ((= ty TNUMBER) (make-number-w (num-value e)))
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
  (let* ((size (ht-size table))
         (h (hashq- key size))
         (buckets (ht-buckets table))
         (bucket0 (vector-ref- buckets h))
         (bucket (if (= (cell-type bucket0) TPAIR) bucket0 cell-nil)))
    (vector-set-x- buckets h (acons key value bucket))
    value))

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
(define (current-module-variable name define-p)
  (let ((var (hashq-ref- m0 name cell-f)))
    (if (and (= var cell-f) (not (= define-p cell-f)))
        (hashq-set-x m0 name (make-variable cell-undefined))
        var)))

; Recursive-evaluator global lookup, now through M0 (E2).
(define (global-lookup sym)
  (let ((var (current-module-variable sym cell-f)))
    (if (= var cell-f) (qfail) (variable-ref var))))

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

(define (qfail) (exit 1))    ; unreachable on the milestone forms

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
  (set! cell-symbol-hashq-table (intern-rsc "<hashq-table>"))
  (set! cell-symbol-variable (intern-rsc "<variable>"))
  (set! cell-symbol-builtin (intern-rsc "<builtin>"))
  (set! cell-symbol-buckets (intern-rsc "buckets"))
  (set! cell-symbol-size (intern-rsc "size"))
  (set! builtin-printer-sym (intern-rsc "builtin-printer"))
  (set! variable-printer-sym (intern-rsc "variable-printer"))
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
  ; math.c
  (bind-builtin "+" ID-PLUS -1)
  (bind-builtin "-" ID-MINUS -1)
  (bind-builtin "=" ID-IS -1)
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
  (bind-builtin "write-char" ID-WRITE-CHAR -1)
  (bind-builtin "core:display-port" ID-DISPLAY-PORT 2)
  (bind-builtin "core:write-port" ID-WRITE-PORT 2)
  (bind-builtin "exit" ID-EXIT 1)
  ; the (*closure* . a) head entry (symbol.c:205)
  (set! env-alist (acons cell-closure env-alist env-alist)))

; ===========================================================================
; Reader (src/reader.c subset)
; ===========================================================================
(define g-input (make-string 1048576))
(define g-input-len 0)
(define g-rd 0)

(define (rd-eof?) (>= g-rd g-input-len))
(define (rd-peek) (if (rd-eof?) -1 (char->integer (string-ref g-input g-rd))))
(define (rd-peek-at k)
  (if (>= (+ g-rd k) g-input-len) -1
      (char->integer (string-ref g-input (+ g-rd k)))))
(define (rd-next) (let ((c (rd-peek))) (set! g-rd (+ g-rd 1)) c))

(define (whitespace? c) (or (= c 32) (= c 9) (= c 10) (= c 13)))
(define (digit? c) (and (>= c 48) (<= c 57)))
(define (delimiter? c)
  (or (< c 0) (whitespace? c) (= c 40) (= c 41) (= c 34) (= c 59)))

(define (skip-line)
  (let ((c (rd-peek)))
    (cond ((< c 0) 'done)
          ((= c 10) (rd-next) 'done)
          (else (rd-next) (skip-line)))))
(define (skip-ws)
  (let ((c (rd-peek)))
    (cond ((< c 0) 'done)
          ((whitespace? c) (rd-next) (skip-ws))
          ((= c 59) (skip-line) (skip-ws))
          (else 'done))))

(define (rd-read)
  (skip-ws)
  (let ((c (rd-peek)))
    (cond
      ((< c 0) cell-eof)
      ((= c 40) (rd-next) (read-list))                       ; (
      ((= c 39) (rd-next) (read-quote cell-symbol-quote))    ; '
      ((= c 96) (rd-next) (read-quote cell-symbol-quasiquote)); `
      ((= c 44) (rd-next) (read-unquote))                    ; ,
      ((= c 34) (rd-next) (read-string))                     ; "
      ((= c 35) (rd-next) (read-hash))                       ; #
      (else (read-atom)))))

(define (read-quote head)
  (let ((x (rd-read)))
    (qcons head (qcons x cell-nil))))
(define (read-unquote)
  (if (= (rd-peek) 64)                                       ; ,@
      (begin (rd-next) (read-quote cell-symbol-unquote-splicing))
      (read-quote cell-symbol-unquote)))

(define (dot? c) (and (= c 46) (delimiter? (rd-peek-at 1))))
(define (read-list)
  (skip-ws)
  (let ((c (rd-peek)))
    (cond
      ((< c 0) cell-nil)
      ((= c 41) (rd-next) cell-nil)
      ((dot? c) (rd-next) (read-dotted-tail))
      (else (let ((hd (rd-read))) (qcons hd (read-list)))))))
(define (read-dotted-tail)
  (let ((tl (rd-read)))
    (skip-ws)
    (rd-next)
    tl))

; read one delimited token, then classify as number or symbol (reader.c parity:
; a token is numeric iff [+-]?[0-9]+, else it is an identifier — so 4a and +44
; read as the symbol 4a and the number 44 respectively).
(define (read-atom)
  (let ((start byte-free))
    (read-symbol-loop)
    (let ((len (- byte-free start)))
      (if (numeric-token? start len)
          (let ((val (parse-number start len)))
            (set! byte-free start)
            val)
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

(define (read-string)
  (let ((start byte-free))
    (read-string-loop)
    (make-strlike TSTRING start (- byte-free start))))
(define (read-string-loop)
  (let ((c (rd-peek)))
    (cond
      ((< c 0) 'done)
      ((= c 34) (rd-next) 'done)
      ((= c 92) (rd-next) (read-string-escape) (read-string-loop))
      (else (rd-next) (bytes-put! (integer->char c)) (read-string-loop)))))
(define (read-string-escape)
  (let ((c (rd-next)))
    (cond
      ((= c 110) (bytes-put! (integer->char 10)))   ; \n
      ((= c 116) (bytes-put! (integer->char 9)))    ; \t
      (else (bytes-put! (integer->char c))))))

(define (read-hash)
  (let ((c (rd-next)))
    (cond ((= c 116) cell-t)                    ; #t
          ((= c 102) cell-f)                    ; #f
          ((= c 92) (read-char-literal))        ; #\
          ((= c 58) (read-keyword))             ; #:
          ((= c 40) (list->vector- (read-list)))  ; #( ... ) vector literal
          (else cell-f))))

(define (read-char-literal)
  (let ((start byte-free))
    (read-symbol-loop)
    (let ((len (- byte-free start)))
      (set! byte-free start)
      (if (<= len 1)
          (make-char (char->integer (string-ref g-input (- g-rd 1))))
          (char-name->char start len)))))
(define (char-name->char start len)
  (cond ((bytes-eq-rsc start len "space") (make-char 32))
        ((bytes-eq-rsc start len "newline") (make-char 10))
        ((bytes-eq-rsc start len "tab") (make-char 9))
        (else (make-char (char->integer (string-ref g-bytes start))))))
(define (bytes-eq-rsc start len str)
  (and (= len (string-length str))
       (bytes-eq-rsc-loop start str 0 len)))
(define (bytes-eq-rsc-loop start str i n)
  (if (= i n) #t
      (if (char=? (string-ref g-bytes (+ start i)) (string-ref str i))
          (bytes-eq-rsc-loop start str (+ i 1) n) #f)))

(define (read-keyword)
  (let ((start byte-free))
    (read-symbol-loop)
    (make-strlike TKEYWORD start (- byte-free start))))

(define (read-symbol)
  (let ((start byte-free))
    (read-symbol-loop)
    (intern start (- byte-free start))))
(define (read-symbol-loop)
  (let ((c (rd-peek)))
    (if (delimiter? c)
        'done
        (begin (rd-next) (bytes-put! (integer->char c)) (read-symbol-loop)))))

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
(define (macro-set-x name value) (hashq-set-x g-macros-table name value))
(define (get-macro name)
  (let ((m (macro-get-handle name)))
    (if (not (= m cell-f)) (cell-car (cell-cdr m)) cell-f)))

; ===========================================================================
; Errors — any error path is a divergence for the gate; print + exit 1.
; ===========================================================================
(define (qerror-unbound x) (qfail))
(define (qerror-args f) (qfail))
(define (qerror-type e) (qfail))

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
        ((w32-eq? (num-value x) (raw-ref (cell-car a) 2)) a)
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
           (if (and (= (cell-type y) TNUMBER) (w32-eq? (num-value x) (num-value y)))
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

(define (display- x fd w)
  (let ((t (cell-type x)))
    (cond
      ((= t TNUMBER) (emit-number fd (num-fixnum x)))
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

; ===========================================================================
; String / list / keyword leaf builtins (string.c, lib.c, vector.c)
; ===========================================================================
(define (bytes->list- off len)
  (if (= len 0) cell-nil
      (qcons (make-char (char->integer (string-ref g-bytes off)))
             (bytes->list- (+ off 1) (- len 1)))))
(define (string->list- s) (bytes->list- (strlike-offset s) (strlike-len s)))
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
(define (b-set-current-input-port port)
  (let ((prev (b-current-input-port)))
    (cond ((= (cell-type port) TNUMBER)
           (let ((p (num-fixnum port))) (set! g-stdin (if (= p 0) 0 p))))
          ((= (cell-type port) TPORT) (set! g-stdin (cell-car port)))
          (else 'ok))
    prev))
; readchar over a string port: read one byte, shrink the port's string cell.
(define (readchar)
  (let* ((port (find-port g-ports)) (s (cell-cdr port)) (len (strlike-len s)))
    (if (= len 0) -1
        (let ((c (char->integer (string-ref g-bytes (strlike-offset s)))))
          (set-cdr! port (make-strlike TSTRING (+ (strlike-offset s) 1) (- len 1)))
          c))))
; read-string (string.c:169) [arity n]: read all of the current input port.
(define (b-read-string x)
  (let ((start byte-free))
    (read-string-all)
    (make-strlike TSTRING start (- byte-free start))))
(define (read-string-all)
  (let ((c (readchar)))
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

; ===========================================================================
; apply_builtin — leaf dispatch on the builtin id (eval-apply.c:382 adapted)
; ===========================================================================
; The dispatch is split into small chained cond blocks: the qfasm assembler
; recurses over each top-level form on the host stack, so one 60-deep nested
; `if` would overflow it.  Keep each sub-dispatcher shallow.
(define (apply-builtin fn x)
  (apply-builtin-core (builtin-id fn) x))
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
    (else (apply-builtin-math id x))))
(define (apply-builtin-math id x)
  (cond
    ((= id ID-PLUS) (b-plus x))
    ((= id ID-MINUS) (b-minus x))
    ((= id ID-IS) (b-is x))
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
    ((= id ID-DISPLAY-PORT) (begin (display- (cell-car x) (port-fd (cell-car (cell-cdr x))) 0) cell-unspec))
    ((= id ID-WRITE-PORT) (begin (display- (cell-car x) (port-fd (cell-car (cell-cdr x))) 1) cell-unspec))
    (else (qfail))))

(define (b-exit x)
  (if (= x cell-nil) (exit 0) (exit (num-fixnum (cell-car x)))))

; ===========================================================================
; main / boot loading (src/mes.c open_boot).
; ===========================================================================
(define g-chunk (make-string 65536))

(define (append-chunk n)
  (let loop ((i 0))
    (if (< i n)
        (begin
          (string-set! g-input g-input-len (string-ref g-chunk i))
          (set! g-input-len (+ g-input-len 1))
          (loop (+ i 1)))
        'ok)))
(define (slurp fd)
  (let ((n (sys-read fd g-chunk)))
    (if (> n 0) (begin (append-chunk n) (slurp fd)) 'done)))

(define (open-boot)
  (let ((mb (getenv "MES_BOOT")))
    (if (not mb)
        -1
        (let ((fd (sys-open mb 0 0)))
          (if (>= fd 0) fd (open-boot-prefix mb))))))
(define (open-boot-prefix mb)
  (let ((pfx (getenv "MES_PREFIX")))
    (if (not pfx)
        -1
        (sys-open (string-append pfx "/mes/module/mes/" mb) 0 0))))

(define floor 0)

(define (read-all-forms)
  (let ((form (rd-read)))
    (if (= form cell-eof) cell-nil (qcons form (read-all-forms)))))

; ===========================================================================
; The VM dispatcher (eval-apply.c:442-504) and the state machine.
; The host-heap safepoint runs first, once per dispatch (design §4).
; Every st-* procedure is only ever tail-called (design §4.4).
; ===========================================================================
(define qmes-no-reset 0)             ; bisect switch (design §4.3.4)

(define (vm-dispatch)
  (if (= qmes-no-reset 0) (host-heap-reset! floor) 'nop)
  (cond
    ((= r3 cell-vm-evlis2)                (st-evlis2))
    ((= r3 cell-vm-evlis3)                (st-evlis3))
    ((= r3 cell-vm-eval-check-func)       (st-eval-check-func))
    ((= r3 cell-vm-eval2)                 (st-eval2))
    ((= r3 cell-vm-apply2)                (st-apply2))
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
      ((= t TCONTINUATION) (qfail))
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
    ((= f cell-symbol-call-with-current-continuation) (qfail))
    ((= f cell-symbol-call-with-values) (qfail))
    ((= f cell-symbol-current-environment) (begin (set! r1 r0) (st-vm-return)))
    (else (st-apply-fallthrough))))
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
          (if (= (cell-car r1) cell-undefined) (qfail)))
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
       (begin (push-cc! (cell-car r1) r1 r0 cell-vm-eval-check-func) (st-eval))))))
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
  (set! g-stdin 0)
  (set! g-stdout 1)
  (set! g-stderr 2)
  ; D6: env-driven arena/stack/byte-pool, allocated below the host-heap floor.
  (set! ARENA-CELLS (env-num "MES_ARENA" 1000000))
  (set! STACK-SIZE (env-num "MES_STACK" 100000))
  (set! g-cells (make-vector (* 3 ARENA-CELLS) 0))
  (set! g-stack (make-vector STACK-SIZE 0))
  (set! g-bytes (make-string BYTE-POOL))
  (init-cells)
  (set! g-ports cell-nil)
  (init-builtins)
  (set! m0 (make-initial-module env-alist))
  (set! m1 cell-f)
  (set! g-macros-table (make-hash-table- 0))
  (let ((fd (open-boot)))
    (if (< fd 0)
        (exit 1)
        (begin (slurp fd) (sys-close fd))))
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

(qmain)
