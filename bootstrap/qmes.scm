; qmes.scm — a Mes-core-compatible Scheme interpreter in the rsc dialect.
;
; This is milestone P2 of the Mes bootstrap: a faithful-in-structure
; transliteration of GNU Mes's C core (third_party/mes/src/*.c) sufficient to
; run scaffold/boot/00-zero.scm .. 14-exit.scm with exit statuses matching the
; reference bin/mes-m2.  It is compiled by the Stage 4 rsc compiler and
; assembled by the seed into a native i386 ELF (see tools/build-qmes.sh).
;
; Representation (per docs/qmes-design.md):
;   A Mes value ("SCM") is an rsc FIXNUM = an index into the cell arena.
;   The cell arena is one rsc VECTOR `g-cells` of 3*NCELLS raw 32-bit words,
;   accessed with the P1 primitives vec-raw-ref / vec-raw-set! (raw machine
;   words boxed as w32).  Cell i occupies words 3i (type), 3i+1 (car),
;   3i+2 (cdr).  Allocation is a bump counter `cell-free`.
;
;   Cell types are Mes's (include/mes/constants.h): TCHAR 0, TNUMBER 6,
;   TPAIR 7, TSPECIAL 10, TSTRING 11, TSYMBOL 13.  Mes stores C function
;   pointers for builtins; qmes cannot, so a builtin is a cell of qmes type
;   TFUNC 20 holding a small builtin-id in its car, and apply dispatches on
;   that id (a cond) to the rsc implementation.  This is the faithful
;   adaptation of the C function-pointer table to a pointer-free host.
;
;   TNUMBER payloads are full 32-bit values kept as P1 w32 boxes and stored
;   RAW in the cell (not fixnum-tagged), because Mes numbers are 32-bit.
;   Type/car/cdr fields are small indices and move through w32-from-fixnum /
;   w32->fixnum.

; ===========================================================================
; Cell type tags
; ===========================================================================
(define TCHAR 0)
(define TNUMBER 6)
(define TPAIR 7)
(define TSPECIAL 10)
(define TSTRING 11)
(define TSYMBOL 13)
(define TFUNC 20)             ; qmes builtin (holds a builtin-id in car)

; Builtin ids (apply dispatches on these)
(define ID-CONS 1)
(define ID-CAR 2)
(define ID-CDR 3)
(define ID-LIST 4)
(define ID-EXIT 5)

; ===========================================================================
; The cell arena (one rsc vector of raw 32-bit words)
; ===========================================================================
; NCELLS = 100000 -> 300000 words.  Milestone forms need only a few dozen
; cells; the margin is for headroom.  The element buffer lives in rsc's byte
; arena (make-vector), so a host-heap reset (which only rewinds the cell
; arena) never disturbs it.
(define g-cells (make-vector 300000 0))
(define cell-free 0)

(define (raw-ref i off) (vec-raw-ref g-cells (+ (* 3 i) off)))
(define (raw-set! i off w) (vec-raw-set! g-cells (+ (* 3 i) off) w))

(define (cell-type i) (w32->fixnum (raw-ref i 0)))
(define (cell-car i) (w32->fixnum (raw-ref i 1)))
(define (cell-cdr i) (w32->fixnum (raw-ref i 2)))

(define (alloc type a d)
  (let ((i cell-free))
    (raw-set! i 0 (w32-from-fixnum type))
    (raw-set! i 1 (w32-from-fixnum a))
    (raw-set! i 2 (w32-from-fixnum d))
    (set! cell-free (+ cell-free 1))
    i))

(define (qcons a d) (alloc TPAIR a d))

; TNUMBER cell: car holds the raw 32-bit value (a w32 box), not a tagged fixnum.
(define (make-number w)
  (let ((i cell-free))
    (raw-set! i 0 (w32-from-fixnum TNUMBER))
    (raw-set! i 1 w)
    (raw-set! i 2 (w32-from-fixnum 0))
    (set! cell-free (+ cell-free 1))
    i))
(define (num-value i) (raw-ref i 1))     ; -> w32 box

; ===========================================================================
; Byte pool: symbol names and string contents (in rsc's byte arena)
; ===========================================================================
(define g-bytes (make-string 1048576))
(define byte-free 0)
(define (bytes-put! ch)
  (string-set! g-bytes byte-free ch)
  (set! byte-free (+ byte-free 1)))
(define (copy-rsc-into-pool str)
  (let loop ((i 0) (n (string-length str)))
    (if (< i n)
        (begin (bytes-put! (string-ref str i)) (loop (+ i 1) n))
        'ok)))

; TSTRING / TSYMBOL cells: car = start offset in g-bytes, cdr = length.
(define (make-mstring start len) (alloc TSTRING start len))

; ===========================================================================
; Fixed cells and the symbol table
; ===========================================================================
(define cell-nil 0)
(define cell-f 0)
(define cell-t 0)
(define cell-unspec 0)
(define cell-dot 0)
(define cell-eof 0)
(define sym-quote 0)
(define sym-if 0)
(define sym-table 0)         ; Mes list of symbol cells (interning table)
(define genv 0)              ; Mes list of (sym . value) pairs (global env)

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
        (if (bytes-equal? (cell-car s) (cell-cdr s) start len)
            s
            (intern-scan (cell-cdr lst) start len)))))

; Intern a name whose bytes already occupy g-bytes[start, byte-free).
(define (intern start len)
  (let ((found (intern-scan sym-table start len)))
    (if found
        (begin (set! byte-free start) found)   ; drop the duplicate copy
        (let ((s (alloc TSYMBOL start len)))
          (set! sym-table (qcons s sym-table))
          s))))

(define (intern-rsc str)
  (let ((start byte-free))
    (copy-rsc-into-pool str)
    (intern start (- byte-free start))))

; ===========================================================================
; Global environment
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

(define (make-func id) (alloc TFUNC id 0))
(define (bind-builtin name id) (env-define! (intern-rsc name) (make-func id)))

(define (qfail) (exit 1))    ; unreachable on the milestone forms

; ===========================================================================
; Initialisation
; ===========================================================================
(define (init-cells)
  (set! cell-nil (alloc TSPECIAL 0 0))
  (set! cell-f (alloc TSPECIAL 0 0))
  (set! cell-t (alloc TSPECIAL 0 0))
  (set! cell-unspec (alloc TSPECIAL 0 0))
  (set! cell-dot (alloc TSPECIAL 0 0))
  (set! cell-eof (alloc TSPECIAL 0 0))
  (set! sym-table cell-nil)
  (set! genv cell-nil)
  (set! sym-quote (intern-rsc "quote"))
  (set! sym-if (intern-rsc "if")))

(define (init-builtins)
  (bind-builtin "cons" ID-CONS)
  (bind-builtin "car" ID-CAR)
  (bind-builtin "cdr" ID-CDR)
  (bind-builtin "list" ID-LIST)
  (bind-builtin "exit" ID-EXIT))

; ===========================================================================
; Reader (src/reader.c subset: ints, #t/#f, strings, symbols, ' , lists incl.
; dotted, ; comments).  Operates over the whole boot file slurped into g-input.
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

; character codes
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
          ((= c 59) (skip-line) (skip-ws))     ; ; comment
          (else 'done))))

(define (rd-read)
  (skip-ws)
  (let ((c (rd-peek)))
    (cond
      ((< c 0) cell-eof)
      ((= c 40) (rd-next) (read-list))                       ; (
      ((= c 39) (rd-next) (read-quote))                      ; '
      ((= c 34) (rd-next) (read-string))                     ; "
      ((= c 35) (rd-next) (read-hash))                       ; #
      ((digit? c) (read-number 1))
      ((and (= c 45) (digit? (rd-peek-at 1))) (rd-next) (read-number -1))
      (else (read-symbol)))))

(define (read-quote)
  (let ((x (rd-read)))
    (qcons sym-quote (qcons x cell-nil))))

(define (dot? c) (and (= c 46) (delimiter? (rd-peek-at 1))))
(define (read-list)
  (skip-ws)
  (let ((c (rd-peek)))
    (cond
      ((< c 0) cell-nil)                        ; malformed: treat as end
      ((= c 41) (rd-next) cell-nil)             ; )
      ((dot? c) (rd-next) (read-dotted-tail))
      (else (let ((hd (rd-read))) (qcons hd (read-list)))))))
(define (read-dotted-tail)
  (let ((tl (rd-read)))
    (skip-ws)
    (rd-next)                                   ; consume )
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
        (make-number
          (if (= sign -1) (w32-sub (w32-from-fixnum 0) acc) acc)))))

(define (read-string)
  (let ((start byte-free))
    (read-string-loop)
    (make-mstring start (- byte-free start))))
(define (read-string-loop)
  (let ((c (rd-peek)))
    (cond
      ((< c 0) 'done)                           ; unterminated
      ((= c 34) (rd-next) 'done)                ; closing "
      ((= c 92) (rd-next) (read-string-escape) (read-string-loop))
      (else (rd-next) (bytes-put! (integer->char c)) (read-string-loop)))))
(define (read-string-escape)
  (let ((c (rd-next)))
    (cond
      ((= c 110) (bytes-put! (integer->char 10)))   ; \n
      ((= c 116) (bytes-put! (integer->char 9)))    ; \t
      (else (bytes-put! (integer->char c))))))      ; \" \\ or literal

(define (read-hash)
  (let ((c (rd-next)))
    (cond ((= c 116) cell-t)                    ; #t
          ((= c 102) cell-f)                    ; #f
          (else cell-f))))

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
; Evaluator (src/eval-apply.c subset: self-eval, symbol lookup, quote, if,
; application of the cons/car/cdr/list/exit builtins).
; ===========================================================================
(define (qeval x)
  (let ((ty (cell-type x)))
    (cond
      ((= ty TSYMBOL) (global-lookup x))
      ((= ty TPAIR) (qeval-pair x))
      (else x))))                               ; number/string/#t/#f/... self-eval

(define (qeval-pair x)
  (let ((op (cell-car x)) (args (cell-cdr x)))
    (cond
      ((= op sym-quote) (cell-car args))        ; (quote X) -> X
      ((= op sym-if) (qeval-if args))
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
  (let ((id (cell-car f)))
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
      (exit (w32->fixnum (num-value (cell-car arglist))))))

; ===========================================================================
; main / boot loading (src/mes.c open_boot).  MES_BOOT is tried verbatim
; first (the scaffold passes an absolute path), then under
; MES_PREFIX/mes/module/mes/.
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

; The safepoint: `floor` is captured once, AFTER every persistent datum (the
; arena vector, byte pools, fixed cells, global env) is allocated.  Each
; top-level form is evaluated, then the host cell arena is rewound to `floor`,
; reclaiming the arg-list pairs / env frames / w32 boxes rsc conses per call.
; This is sound because every durable qmes datum is either a fixnum index
; (immediate) or lives in the byte arena (g-cells/g-bytes/g-input), none of
; which the reset touches (see docs/qmes-design.md).
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
