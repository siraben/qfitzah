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
(define TFUNC 20)             ; qmes builtin (holds a builtin-id in car, arity in cdr)

; ===========================================================================
; The cell arena (one rsc vector of raw 32-bit words)
; ===========================================================================
(define NCELLS 1000000)
(define g-cells (make-vector 3000000 0))
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
(define g-bytes (make-string 2097152))
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

; Global environment (recursive-evaluator path; replaced by M0 in E2/E3)
(define genv 0)

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
; Global environment (recursive evaluator; E1/E2 only)
; ===========================================================================
(define (env-define! sym val) (set! genv (qcons (qcons sym val) genv)))
(define (env-scan lst sym)
  (if (= lst cell-nil)
      #f
      (let ((pr (cell-car lst)))
        (if (= (cell-car pr) sym) pr (env-scan (cell-cdr lst) sym)))))
(define (global-lookup sym)
  (let ((pr (env-scan genv sym)))
    (if pr (cell-cdr pr) (qfail))))

; TFUNC builtin: car = builtin-id, cdr = arity (-1 = n-ary).
(define (make-func id arity) (alloc TFUNC id arity))
(define (func-id f) (cell-car f))
(define (func-arity f) (cell-cdr f))
(define (bind-builtin name id arity)
  (env-define! (intern-rsc name) (make-func id arity)))

(define (qfail) (exit 1))    ; unreachable on the milestone forms

; Builtin ids
(define ID-CONS 1)
(define ID-CAR 2)
(define ID-CDR 3)
(define ID-LIST 4)
(define ID-EXIT 5)

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
  (set! genv cell-nil)

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
  (set! cell-symbol-program (intern-rsc "%program"))
  (set! cell-symbol-portable-macro-expand (intern-rsc "portable-macro-expand"))
  (set! cell-symbol-sc-expander-alist (intern-rsc "*sc-expander-alist*"))
  (set! cell-symbol-macro-expand (intern-rsc "macro-expand")))

(define (init-builtins)
  (bind-builtin "cons" ID-CONS 2)
  (bind-builtin "car" ID-CAR 1)
  (bind-builtin "cdr" ID-CDR 1)
  (bind-builtin "list" ID-LIST -1)
  (bind-builtin "exit" ID-EXIT 1))

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
      ((digit? c) (read-number 1))
      ((and (= c 45) (digit? (rd-peek-at 1))) (rd-next) (read-number -1))
      (else (read-symbol)))))

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

(define (read-number sign)
  (read-number-loop (w32-from-fixnum 0) sign))
(define (read-number-loop acc sign)
  (let ((c (rd-peek)))
    (if (digit? c)
        (begin
          (rd-next)
          (read-number-loop
            (w32-add (w32-mul acc (w32-from-fixnum 10))
                     (w32-from-fixnum (- c 48)))
            sign))
        (make-number-w
          (if (= sign -1) (w32-sub (w32-from-fixnum 0) acc) acc)))))

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
; Recursive evaluator (E1/E2 — replaced by the VM in E3).
; ===========================================================================
(define (qeval x)
  (let ((ty (cell-type x)))
    (cond
      ((= ty TSYMBOL) (global-lookup x))
      ((= ty TPAIR) (qeval-pair x))
      (else x))))

(define (qeval-pair x)
  (let ((op (cell-car x)) (args (cell-cdr x)))
    (cond
      ((= op cell-symbol-quote) (cell-car args))
      ((= op cell-symbol-if) (qeval-if args))
      (else (qapply (qeval op) (qevlis args))))))

(define (qeval-if args)
  (let ((test (qeval (cell-car args))))
    (if (= test cell-f)
        (let ((els (cell-cdr (cell-cdr args))))
          (if (= els cell-nil) cell-unspec (qeval (cell-car els))))
        (qeval (cell-car (cell-cdr args))))))

(define (qevlis args)
  (if (= args cell-nil)
      cell-nil
      (qcons (qeval (cell-car args)) (qevlis (cell-cdr args)))))

(define (qapply f arglist)
  (let ((id (func-id f)))
    (cond
      ((= id ID-CONS) (qcons (cell-car arglist) (cell-car (cell-cdr arglist))))
      ((= id ID-CAR) (cell-car (cell-car arglist)))
      ((= id ID-CDR) (cell-cdr (cell-car arglist)))
      ((= id ID-LIST) arglist)
      ((= id ID-EXIT) (b-exit arglist))
      (else (qfail)))))

(define (b-exit arglist)
  (if (= arglist cell-nil)
      (exit 0)
      (exit (num-fixnum (cell-car arglist)))))

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

(define (run-forms)
  (let ((form (rd-read)))
    (if (= form cell-eof)
        (exit 0)
        (begin
          (qeval form)
          (host-heap-reset! floor)
          (run-forms)))))

(define (qmain)
  (init-cells)
  (init-builtins)
  (let ((fd (open-boot)))
    (if (< fd 0)
        (exit 1)
        (begin
          (slurp fd)
          (sys-close fd)
          (set! floor (w32-add (host-heap-mark) (w32-from-fixnum 64)))
          (run-forms))))
  (exit 0))

(qmain)
