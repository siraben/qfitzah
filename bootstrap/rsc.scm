; rsc.scm -- Stage 4 of the bootstrap ladder: an R5RS-subset Scheme-to-qfasm
; compiler written strictly in the sc1 subset, so sc1 compiles it AND it
; self-hosts (rsc recompiles its own source to a byte-identical fixpoint).
; It is sc1's codegen preceded by a hygienic macro-expansion pass, adding
; over sc1: syntax-rules macros, quasiquote, the derived special forms
; (let*/letrec/named-let/case/when/unless/do/cond=>), vectors, and
; tail-proper apply/varargs.
;
; This is the top of the compiler ladder: everything above it -- the native
; assembler asm.scm, the qmes Mes interpreter, the generators -- is written
; in "the rsc dialect" and compiled by rsc.elf.  The ascent: sc1.elf compiles
; rsc.scm -> rscA.elf; rscA recompiles rsc.scm -> rscB; rscB recompiles it
; again -> rscC; the suite requires B == C byte-identical.  The first half of
; this file (through emit-globals) is line-for-line the sc1.scm codegen --
; only prim-names grows -- and its commentary is repeated here so the file
; reads on its own; the Stage 4 material starts at the "Macro expander"
; banner below.
;
; Prepend bootstrap/sc1-reader.scm (the reader) before this file.  Programs
; that rsc compiles are prepended with bootstrap/rsc-prelude.scm (the Scheme
; standard-library layer); rsc.scm itself stays in the sc1 subset and uses none
; of the prelude, so its fixpoint re-exercises sc1's codegen.  The last
; top-level form, (main), reads the remaining stdin as the program to compile
; and emits a complete qfasm program on stdout:
;
;   (Assemble (Program Start (X8 ...) <instruction chain> ))
;
; whose fixed runtime is supplied by bootstrap/rsc-runtime.qf1 via the
; (RuntimeCode ...) / (RuntimeData ...) macros.  Assemble the emitted text with:
;   cat qfasm.qf1 rsc-runtime.qf1 out.qfasm | qfitzah > out.elf
;
; Compilation model (see sc1-runtime.qf1 for the value representation):
;   * EBP holds the current environment: a heap list of frames, each frame a
;     list of the argument values bound in one lambda scope. Variables compile
;     to lexical (depth,index) walks; free variables are global static cells.
;   * A callable is an object (subtype 2) whose payload pair is (code . env).
;     Apply builds the argument list in EDX, extracts code (ESI) and captured
;     env (EDI), and CALLs (non-tail) or JMPs (tail) the code. Tail calls do
;     not grow the machine stack, so tail recursion runs in constant space.
;   * Primitives are ordinary global closures built by the runtime's InitPrims.
;
; Value tagging (shared with scheme0; the constants below make sense only
; against this table).  The low two bits of a 32-bit word give the type:
;   00  pair pointer          01  fixnum (value = word >> 2)
;   10  object pointer        11  immediate:
;       0x03 '()   0x13 #t   0x23 #f   0x33 eof   0x43 unspecified
;       (char c) = (c << 8) | 0x53
; An object (tag 10) points at a header pair whose car is the payload pointer
; with a subtype in ITS low bits: 0 symbol, 1 string, 2 closure, 4 vector.

; ---------------------------------------------------------------------------
; Small list helpers not provided by the reader.
; ---------------------------------------------------------------------------
(define (caar x) (car (car x)))
(define (cdddr x) (cdr (cddr x)))
(define (cadddr x) (car (cdddr x)))
(define (map1 f l) (if (null? l) '() (cons (f (car l)) (map1 f (cdr l)))))
(define (repeat n th) (if (= n 0) #f (begin (th) (repeat (- n 1) th))))

; ---------------------------------------------------------------------------
; Output primitives (the compiler produces its result by side effect).
; ---------------------------------------------------------------------------
(define (o-str s) (display s))
(define (o-num n) (display n))
(define (o-sym s) (display (symbol->string s)))

(define hexdigits "0123456789ABCDEF")
(define (emit-hex-digit d) (display (string-ref hexdigits d)))
(define (emit-hex-byte b)
  (emit-hex-digit (quotient b 16))
  (emit-hex-digit (remainder b 16)))

; Eight nybbles (low-to-high) of (w mod 2^32); handles negative w via
; floor-mod so tagged negative fixnums emit correct two's-complement hex.
(define (floor-mod16 w) (remainder (+ (remainder w 16) 16) 16))
(define (nib8 w) (nib8-loop w 8))
(define (nib8-loop w k)
  (if (= k 0)
      '()
      (let ((r (floor-mod16 w)))
        (cons r (nib8-loop (quotient (- w r) 16) (- k 1))))))
(define (emit-x8 w)
  (o-str "(X8 ")
  (emit-nibs-be (reverse (nib8 w)))
  (o-str ")"))
(define (emit-nibs-be lst)
  (if (null? lst)
      #f
      (begin (emit-hex-digit (car lst))
             (if (null? (cdr lst)) #f (o-str " "))
             (emit-nibs-be (cdr lst)))))

; ---------------------------------------------------------------------------
; Instruction chain emission. The qfasm program is ONE right-nested term:
; (Ins i1 (Ins i2 (... End))). Each (Ins X ...) opens one paren that is closed
; at the very end; ins-count tracks how many are open. `ins` takes a literal
; instruction string; `ins-dyn` takes a thunk for instructions with computed
; operands.
; ---------------------------------------------------------------------------
(define ins-count 0)
(define (ins s)
  (o-str "(Ins ")
  (o-str s)
  (newline)
  (set! ins-count (+ ins-count 1)))
(define (ins-dyn th)
  (o-str "(Ins ")
  (th)
  (newline)
  (set! ins-count (+ ins-count 1)))

(define (emit-jz32 n) (ins-dyn (lambda () (o-str "(Jz32 (Lb ") (o-num n) (o-str "))"))))
(define (emit-jnz32 n) (ins-dyn (lambda () (o-str "(Jnz32 (Lb ") (o-num n) (o-str "))"))))
(define (emit-jmp32 n) (ins-dyn (lambda () (o-str "(Jmp32 (Lb ") (o-num n) (o-str "))"))))
(define (emit-label n) (ins-dyn (lambda () (o-str "(Label (Lb ") (o-num n) (o-str "))"))))
(define (emit-cdr-eax) (ins "(MovRMD EAX EAX 04)"))
(define (emit-car-eax) (ins "(MovRM EAX EAX)"))

; Immediates, straight from the tagging table above: #t = 0x13, #f = 0x23,
; '() = 3, unspecified = 0x43.  (X8 ...) is qfasm's big-endian-nybble 32-bit
; literal; (Small n) a small hex literal.
(define (load-true) (ins "(MovRI EAX (X8 0 0 0 0 0 0 1 3))"))
(define (load-false) (ins "(MovRI EAX (X8 0 0 0 0 0 0 2 3))"))
(define (load-nil) (ins "(MovRI EAX (Small 3))"))
(define (load-unspec) (ins "(MovRI EAX (X8 0 0 0 0 0 0 4 3))"))
(define cmp-false "(CmpEaxI32 (X8 0 0 0 0 0 0 2 3))")

; ---------------------------------------------------------------------------
; Compile-time state.  All label numbering flows from `fresh`, so compilation
; is deterministic: the same source always yields the same label numbers,
; which is what makes the self-host fixpoint byte-identical.
; ---------------------------------------------------------------------------
(define counter 0)
(define (fresh) (set! counter (+ counter 1)) counter)

(define user-globals '())      ; non-primitive global names needing a cell
(define pending-procs '())     ; deferred lambda bodies: (label params body ctenv)
(define pending-data '())      ; deferred static data: list of thunks
(define sym-table '())         ; interned quoted symbols: (symbol . litnum)
(define static-syms '())       ; symbols to push onto GObList at startup

; sc1's primitive set plus the Stage 4 additions: mutable strings, vectors,
; and a tail-proper apply (the runtime's PrApply splices the argument list
; and JMPs into the callee, so (apply f args) in tail position is itself a
; tail call).
(define prim-names
  '(cons car cdr set-car! set-cdr! pair? null? eq? eqv? symbol? number?
    string? char? procedure? boolean? not + - * quotient remainder = < > <= >=
    display write newline read-char peek-char eof-object? char->integer
    integer->char string-length string-ref string->symbol symbol->string
    list->string make-string string-set! apply
    make-vector vector vector-ref vector-set! vector-length vector?
    vector->list list->vector error exit))
(define (is-prim? name) (if (memq name prim-names) #t #f))

(define (register-global name)
  (if (or (is-prim? name) (memq name user-globals))
      #f
      (set! user-globals (cons name user-globals))))

(define (gv-load name)
  (ins-dyn (lambda () (o-str "(MovRMemL EAX (GV ") (o-sym name) (o-str "))"))))
(define (gv-store name)
  (ins-dyn (lambda () (o-str "(MovMemLR (GV ") (o-sym name) (o-str ") EAX)"))))

(define (push-data th) (set! pending-data (cons th pending-data)))

; ---------------------------------------------------------------------------
; Compile-time environment: a list of frames, each a list of parameter names.
; It mirrors the run-time environment in EBP exactly, so a hit at frame d,
; slot i compiles to d cdr-steps, a car, i cdr-steps, and a car.  A miss means
; the name is a global (there is no intermediate scope in this Scheme).
; ---------------------------------------------------------------------------
(define (ct-lookup name env) (ct-lookup2 name env 0))
(define (ct-lookup2 name env d)
  (if (null? env)
      #f
      (let ((i (index-of name (car env) 0)))
        (if i (cons d i) (ct-lookup2 name (cdr env) (+ d 1))))))
(define (index-of name frame i)
  (cond ((null? frame) #f)
        ((eq? name (car frame)) i)
        (else (index-of name (cdr frame) (+ i 1)))))

; ---------------------------------------------------------------------------
; Quoted data -> static values. A token is (kind . info):
;   imm     info = 32-bit tagged word    pairlbl info = (Lit n) label number
;   objlbl  info = (Lit n) label number (symbol/string object pointer)
; Compound data is emitted as static cells in the data section (via the
; pending-data worklist) and referenced by label, so quoting costs no run-time
; allocation.  The imm encodings are the tagging table verbatim: fixnum n ->
; 4n+1, #t -> 19, #f -> 35, char c -> 256c+83, '() -> 3.
; ---------------------------------------------------------------------------
(define (quote-datum d)
  (cond ((number? d) (cons 'imm (+ (* d 4) 1)))
        ((boolean? d) (cons 'imm (if d 19 35)))
        ((char? d) (cons 'imm (+ (* (char->integer d) 256) 83)))
        ((null? d) (cons 'imm 3))
        ((string? d)
         (let ((n (fresh)))
           (push-data (lambda () (emit-string-data d n)))
           (cons 'objlbl n)))
        ((symbol? d) (intern-quoted-symbol d))
        ((pair? d)
         (let ((n (fresh)))
           (let ((tcar (quote-datum (car d))) (tcdr (quote-datum (cdr d))))
             (push-data (lambda () (emit-pair-data n tcar tcdr)))
             (cons 'pairlbl n))))
        (else (cons 'imm 3))))

; Quoted symbols are interned at compile time: one static object per distinct
; symbol, remembered in sym-table so every 'foo in the program shares it (eq?
; on symbols is then pointer equality).  static-syms additionally schedules
; the symbol for GObList at startup, so string->symbol at run time finds the
; static object instead of creating a duplicate.
(define (intern-quoted-symbol sym)
  (let ((e (assq sym sym-table)))
    (if e
        (cons 'objlbl (cdr e))
        (let ((n (fresh)))
          (set! sym-table (cons (cons sym n) sym-table))
          (set! static-syms (cons (cons sym n) static-syms))
          (push-data (lambda () (emit-sym-data sym n)))
          (cons 'objlbl n)))))

(define (emit-load tok)
  (let ((k (car tok)) (info (cdr tok)))
    (cond ((eq? k 'imm)
           (ins-dyn (lambda () (o-str "(MovRI EAX ") (emit-x8 info) (o-str ")"))))
          ((eq? k 'pairlbl)
           (ins-dyn (lambda () (o-str "(MovRILabel EAX (Lit ") (o-num info) (o-str "))"))))
          (else
           (ins-dyn (lambda () (o-str "(MovRIObj EAX (Lit ") (o-num info) (o-str "))")))))))

(define (emit-field tok)
  (let ((k (car tok)) (info (cdr tok)))
    (cond ((eq? k 'imm) (o-str "(Dd ") (emit-x8 info) (o-str ")"))
          ((eq? k 'pairlbl) (o-str "(DLabel (Lit ") (o-num info) (o-str "))"))
          (else (o-str "(DObj (Lit ") (o-num info) (o-str "))")))))

(define (emit-bytes-of-string s) (emit-bytes-loop s 0 (string-length s)))
(define (emit-bytes-loop s i n)
  (if (= i n)
      #f
      (begin
        (ins-dyn (lambda () (o-str "(Db ") (emit-hex-byte (char->integer (string-ref s i))) (o-str ")")))
        (emit-bytes-loop s (+ i 1) n))))

; Static object layout (strings and symbols): first the raw bytes at label
; (LitB n), then -- 8-byte aligned, since the tag bits of the pointer must be
; free -- the header pair at (Lit n): car = byte pointer with the subtype in
; its low bits (DConst adds 1: string; DLabel adds 0: symbol), cdr = the
; length as a tagged fixnum (4*len+1).
(define (emit-string-data s n)
  (ins "(Align8)")
  (ins-dyn (lambda () (o-str "(Label (LitB ") (o-num n) (o-str "))")))
  (emit-bytes-of-string s)
  (ins "(Align8)")
  (ins-dyn (lambda () (o-str "(Label (Lit ") (o-num n) (o-str "))")))
  (ins-dyn (lambda () (o-str "(DConst (LitB ") (o-num n) (o-str "))")))
  (ins-dyn (lambda () (o-str "(Dd ") (emit-x8 (+ (* (string-length s) 4) 1)) (o-str ")"))))

(define (emit-sym-data sym n)
  (let ((s (symbol->string sym)))
    (ins "(Align8)")
    (ins-dyn (lambda () (o-str "(Label (LitB ") (o-num n) (o-str "))")))
    (emit-bytes-of-string s)
    (ins "(Align8)")
    (ins-dyn (lambda () (o-str "(Label (Lit ") (o-num n) (o-str "))")))
    (ins-dyn (lambda () (o-str "(DLabel (LitB ") (o-num n) (o-str "))")))
    (ins-dyn (lambda () (o-str "(Dd ") (emit-x8 (+ (* (string-length s) 4) 1)) (o-str ")")))))

(define (emit-pair-data n tcar tcdr)
  (ins "(Align8)")
  (ins-dyn (lambda () (o-str "(Label (Lit ") (o-num n) (o-str "))")))
  (ins-dyn (lambda () (emit-field tcar)))
  (ins-dyn (lambda () (emit-field tcdr))))

; ---------------------------------------------------------------------------
; Desugaring.  let and cond are the only sugar the CODEGEN accepts (rsc's
; other surface forms are handled by the expander before they get here);
; both rewrite to core forms exactly as R5RS 7.3 derives them:
; (let ((v e) ...) body) => ((lambda (v ...) body) e ...), and cond => nested
; ifs (an else clause becomes the final alternative; a cond that falls off
; the end yields (if #f #f), the unspecified value).
; ---------------------------------------------------------------------------
(define (let->lambda expr)
  (let ((binds (cadr expr)) (body (cddr expr)))
    (cons (cons 'lambda (cons (map1 (lambda (b) (car b)) binds) body))
          (map1 (lambda (b) (cadr b)) binds))))

(define (cond->if clauses)
  (if (null? clauses)
      (list 'if #f #f)
      (let ((cl (car clauses)))
        (if (eq? (car cl) 'else)
            (cons 'begin (cdr cl))
            (list 'if (car cl) (cons 'begin (cdr cl)) (cond->if (cdr clauses)))))))

; ---------------------------------------------------------------------------
; Parameter lists: names, fixed count, rest presence.  A parameter list is
; proper ((a b)), dotted ((a . r)), or a bare symbol (r); the rest name, if
; any, is just the last entry of param-names, so it occupies the frame slot
; after the fixed parameters.
; ---------------------------------------------------------------------------
(define (param-names params)
  (cond ((symbol? params) (list params))
        ((null? params) '())
        ((pair? params) (cons (car params) (param-names (cdr params))))
        (else '())))
(define (has-rest? params)
  (cond ((symbol? params) #t)
        ((null? params) #f)
        ((pair? params) (has-rest? (cdr params)))
        (else #f)))
(define (fixed-count params)
  (cond ((symbol? params) 0)
        ((null? params) 0)
        ((pair? params) (+ 1 (fixed-count (cdr params))))
        (else 0)))

; ---------------------------------------------------------------------------
; Expression compilation. compile-expr leaves the value in EAX (non-tail);
; compile-tail leaves via RET or a tail JMP.  The tail/non-tail split is the
; whole tail-call discipline: every form that can end a procedure body has a
; tail variant that never falls through, so a tail call compiles to JMP and
; recursion in tail position runs in constant stack (R5RS 3.5).
; ---------------------------------------------------------------------------
(define (compile-expr expr ctenv)
  (cond ((number? expr) (ins-dyn (lambda () (o-str "(MovRI EAX ") (emit-x8 (+ (* expr 4) 1)) (o-str ")"))))
        ((boolean? expr) (if expr (load-true) (load-false)))
        ((char? expr) (ins-dyn (lambda () (o-str "(MovRI EAX ") (emit-x8 (+ (* (char->integer expr) 256) 83)) (o-str ")"))))
        ((string? expr)
         (let ((n (fresh)))
           (push-data (lambda () (emit-string-data expr n)))
           (ins-dyn (lambda () (o-str "(MovRIObj EAX (Lit ") (o-num n) (o-str "))")))))
        ((null? expr) (load-nil))
        ((symbol? expr) (compile-var expr ctenv))
        ((pair? expr) (compile-form expr ctenv))
        (else (load-unspec))))

(define (compile-form expr ctenv)
  (let ((op (car expr)))
    (cond ((eq? op 'quote) (emit-load (quote-datum (cadr expr))))
          ((eq? op 'if) (compile-if expr ctenv #f))
          ((eq? op 'define) (compile-define expr ctenv))
          ((eq? op 'set!) (compile-set expr ctenv))
          ((eq? op 'lambda) (compile-lambda expr ctenv))
          ((eq? op 'begin) (compile-begin (cdr expr) ctenv #f))
          ((eq? op 'let) (compile-expr (let->lambda expr) ctenv))
          ((eq? op 'cond) (compile-expr (cond->if (cdr expr)) ctenv))
          ((eq? op 'and) (compile-and (cdr expr) ctenv))
          ((eq? op 'or) (compile-or (cdr expr) ctenv))
          (else (compile-app expr ctenv #f)))))

(define (compile-tail expr ctenv)
  (if (pair? expr)
      (let ((op (car expr)))
        (cond ((eq? op 'if) (compile-if expr ctenv #t))
              ((eq? op 'begin) (compile-begin (cdr expr) ctenv #t))
              ((eq? op 'let) (compile-tail (let->lambda expr) ctenv))
              ((eq? op 'cond) (compile-tail (cond->if (cdr expr)) ctenv))
              ((eq? op 'quote) (emit-load (quote-datum (cadr expr))) (ins "(Ret)"))
              ((eq? op 'define) (compile-define expr ctenv) (ins "(Ret)"))
              ((eq? op 'set!) (compile-set expr ctenv) (ins "(Ret)"))
              ((eq? op 'lambda) (compile-lambda expr ctenv) (ins "(Ret)"))
              ((eq? op 'and) (compile-and (cdr expr) ctenv) (ins "(Ret)"))
              ((eq? op 'or) (compile-or (cdr expr) ctenv) (ins "(Ret)"))
              (else (compile-app expr ctenv #t))))
      (begin (compile-expr expr ctenv) (ins "(Ret)"))))

; A lexical variable is a (depth . index) walk down the EBP environment; a
; free variable is a global cell, created on first reference (a reference
; before any definition simply reads the zero-initialised cell).
(define (compile-var name ctenv)
  (let ((loc (ct-lookup name ctenv)))
    (if loc
        (begin (ins "(MovRR EAX EBP)")
               (repeat (car loc) emit-cdr-eax)
               (emit-car-eax)
               (repeat (cdr loc) emit-cdr-eax)
               (emit-car-eax))
        (begin (register-global name) (gv-load name)))))

; if: test, compare against #f (everything else is true), Jz to the else
; label.  In tail position both arms leave via compile-tail/RET, so no join
; label is needed; non-tail needs the usual jump over the else arm to a join.
; A missing else arm yields the unspecified value.
(define (compile-if expr ctenv tail?)
  (let ((test (cadr expr)) (then (caddr expr)) (haselse (pair? (cdddr expr))))
    (compile-expr test ctenv)
    (ins cmp-false)
    (let ((elab (fresh)))
      (emit-jz32 elab)
      (if tail? (compile-tail then ctenv) (compile-expr then ctenv))
      (if tail?
          (begin (emit-label elab)
                 (if haselse
                     (compile-tail (cadddr expr) ctenv)
                     (begin (load-unspec) (ins "(Ret)"))))
          (let ((endlab (fresh)))
            (emit-jmp32 endlab)
            (emit-label elab)
            (if haselse (compile-expr (cadddr expr) ctenv) (load-unspec))
            (emit-label endlab))))))

(define (compile-begin body ctenv tail?)
  (cond ((null? body) (if tail? (begin (load-unspec) (ins "(Ret)")) (load-unspec)))
        ((null? (cdr body))
         (if tail? (compile-tail (car body) ctenv) (compile-expr (car body) ctenv)))
        (else (compile-expr (car body) ctenv) (compile-begin (cdr body) ctenv tail?))))

; and/or: short-circuit on one shared exit label; the value of the deciding
; subexpression is already in EAX when we jump, which is exactly the R5RS
; result ((or a b) returns a itself when a is true, not #t).
(define (compile-and args ctenv)
  (if (null? args) (load-true) (compile-and-loop args ctenv (fresh))))
(define (compile-and-loop args ctenv end)
  (if (null? (cdr args))
      (begin (compile-expr (car args) ctenv) (emit-label end))
      (begin (compile-expr (car args) ctenv)
             (ins cmp-false)
             (emit-jz32 end)
             (compile-and-loop (cdr args) ctenv end))))

(define (compile-or args ctenv)
  (if (null? args) (load-false) (compile-or-loop args ctenv (fresh))))
(define (compile-or-loop args ctenv end)
  (if (null? (cdr args))
      (begin (compile-expr (car args) ctenv) (emit-label end))
      (begin (compile-expr (car args) ctenv)
             (ins cmp-false)
             (emit-jnz32 end)
             (compile-or-loop (cdr args) ctenv end))))

(define (compile-set expr ctenv)
  (let ((name (cadr expr)) (val (caddr expr)))
    (let ((loc (ct-lookup name ctenv)))
      (if loc
          (begin (compile-expr val ctenv)
                 (ins "(PushR EAX)")
                 (ins "(MovRR EAX EBP)")
                 (repeat (car loc) emit-cdr-eax)
                 (emit-car-eax)
                 (repeat (cdr loc) emit-cdr-eax)
                 (ins "(PopR ECX)")
                 (ins "(MovMR EAX ECX)")
                 (load-unspec))
          (begin (compile-expr val ctenv)
                 (register-global name)
                 (gv-store name)
                 (load-unspec))))))

; define: the (define (f args) body) shorthand rewrites to a lambda; the
; value lands in a global cell.  Internal defines are not scoped -- a define
; anywhere stores to the global, which is why the ladder's sources only use
; top-level define.
(define (compile-define expr ctenv)
  (let ((target (cadr expr)))
    (if (pair? target)
        (compile-define
         (list 'define (car target)
               (cons 'lambda (cons (cdr target) (cddr expr))))
         ctenv)
        (begin
          (if (null? (cddr expr)) (load-unspec) (compile-expr (caddr expr) ctenv))
          (register-global target)
          (gv-store target)
          (load-unspec)))))

; lambda: the body is deferred to the pending-procs worklist (emitted after
; the top level, see emit-proc); here we just build the closure object:
;   payload = Cons(code-label, EBP)      the pair (code . captured-env)
;   OrI8 02                              mark payload as subtype 2 (closure)
;   header  = Cons(payload|2, 1)         cdr is an untagged spare word
;   OrI8 02                              tag the header pointer as an object
; compile-app below undoes this layer for layer.
(define (compile-lambda expr ctenv)
  (let ((params (cadr expr)) (body (cddr expr)) (p (fresh)))
    (set! pending-procs (cons (list p params body ctenv) pending-procs))
    (ins-dyn (lambda () (o-str "(MovRILabel EAX (Proc ") (o-num p) (o-str "))")))
    (ins "(MovRR ECX EBP)")
    (ins "(Call Cons)")
    (ins "(OrI8 EAX 02)")
    (ins "(MovRI ECX (Small 1))")
    (ins "(Call Cons)")
    (ins "(OrI8 EAX 02)")))

; Application.  Evaluate the operator, park it on the machine stack, evaluate
; the arguments left to right pushing each, then pop them off into a heap
; list built back to front (so it comes out in order) in EDX.  Then take the
; closure apart:
;   SubI8 ESI 02   untag the object pointer
;   MovRM  ESI     load the header's car (payload|subtype)
;   AndI8  ESI F8  clear the subtype bits -> payload pair
;   EDI = cdr      the captured environment (emit-prologue conses onto it)
;   ESI = car      the code address
; EAX carries the argument list into the callee.  Non-tail: save the caller's
; EBP around a CALL.  Tail: JMP -- the stack is exactly as our own caller left
; it, so tail calls consume no stack (this is what makes the compiler's own
; recursive loops safe when it compiles itself).
(define (compile-app expr ctenv tail?)
  (compile-expr (car expr) ctenv)
  (ins "(PushR EAX)")
  (push-args (cdr expr) ctenv)
  (ins "(MovRI EDX (Small 3))")
  (build-arglist (length (cdr expr)))
  (ins "(PopR EAX)")
  (ins "(MovRR ESI EAX)")
  (ins "(SubI8 ESI 02)")
  (ins "(MovRM ESI ESI)")
  (ins "(AndI8 ESI F8)")
  (ins "(MovRMD EDI ESI 04)")
  (ins "(MovRM ESI ESI)")
  (ins "(MovRR EAX EDX)")
  (if tail?
      (ins "(JmpR ESI)")
      (begin (ins "(PushR EBP)") (ins "(CallR ESI)") (ins "(PopR EBP)"))))
(define (push-args args ctenv)
  (if (null? args)
      #f
      (begin (compile-expr (car args) ctenv)
             (ins "(PushR EAX)")
             (push-args (cdr args) ctenv))))
(define (build-arglist n)
  (if (= n 0)
      #f
      (begin (ins "(PopR EAX)")
             (ins "(MovRR ECX EDX)")
             (ins "(Call Cons)")
             (ins "(MovRR EDX EAX)")
             (build-arglist (- n 1)))))

; ---------------------------------------------------------------------------
; Lambda-body (procedure) emission.  A procedure entry receives its argument
; list in EAX and its captured environment in EDI (set up by compile-app);
; the prologue turns those into the new EBP environment, and the body is then
; compiled in tail position against a compile-time env extended with the
; parameter frame.
; ---------------------------------------------------------------------------
(define (emit-proc p params body ctenv)
  (ins-dyn (lambda () (o-str "(Label (Proc ") (o-num p) (o-str "))")))
  (emit-prologue params)
  (compile-tail (cons 'begin body) (cons (param-names params) ctenv)))

; EBP := (frame . captured-env), with the frame in EAX and EDI holding the
; captured env.
(define (bind-newenv)
  (ins "(MovRR ECX EDI)")
  (ins "(Call Cons)")
  (ins "(MovRR EBP EAX)"))

; Prologue by parameter shape:
;   (a b c)   the argument list IS the frame: just bind-newenv.
;   r         wrap the whole argument list: frame = (arglist).
;   (a b . r) walk ESI to the (k-1)th cell of the argument list, lift its
;             cdr (the excess arguments) out, box it as a one-element tail
;             (rest-list), and splice that back in, so the frame becomes
;             (a1 .. ak rest-list) and r sits at index k.  This MUTATES the
;             final cons of the caller-built argument list, which is fresh
;             per call, so no sharing is violated.
(define (emit-prologue params)
  (cond ((symbol? params)
         (ins "(MovRI ECX (Small 3))")
         (ins "(Call Cons)")
         (bind-newenv))
        ((has-rest? params)
         (let ((k (fixed-count params)))
           (ins "(MovRR ESI EAX)")
           (repeat (- k 1) (lambda () (ins "(MovRMD ESI ESI 04)")))
           (ins "(MovRMD ECX ESI 04)")
           (ins "(PushR EAX)")
           (ins "(PushR ESI)")
           (ins "(MovRR EAX ECX)")
           (ins "(MovRI ECX (Small 3))")
           (ins "(Call Cons)")
           (ins "(PopR ESI)")
           (ins "(MovMDR ESI 04 EAX)")
           (ins "(PopR EAX)")
           (bind-newenv)))
        (else (bind-newenv))))

; ---------------------------------------------------------------------------
; Draining the worklists.  pending-procs is drained LIFO -- and emit-proc may
; push more (nested lambdas) which are then drained first; pending-data is
; reversed so data appears in creation order.  Both orders are deterministic
; functions of the source, part of the fixpoint contract.
; ---------------------------------------------------------------------------
(define (drain-procs)
  (if (null? pending-procs)
      #f
      (let ((p (car pending-procs)))
        (set! pending-procs (cdr pending-procs))
        (emit-proc (car p) (cadr p) (caddr p) (cadddr p))
        (drain-procs))))

(define (drain-data)
  (drain-data2 (reverse pending-data)))
(define (drain-data2 lst)
  (if (null? lst) #f (begin ((car lst)) (drain-data2 (cdr lst)))))

; InternStatics is called once at startup: it pushes every statically
; emitted symbol onto the runtime's oblist (GObList) so run-time
; string->symbol interns into the same identity space as compile time.
(define (emit-internstatics)
  (ins "(Label InternStatics)")
  (emit-static-syms static-syms)
  (ins "(Ret)"))
(define (emit-static-syms lst)
  (if (null? lst)
      #f
      (let ((n (cdr (car lst))))
        (ins-dyn (lambda () (o-str "(MovRIObj EAX (Lit ") (o-num n) (o-str "))")))
        (ins "(MovRMemL ECX GObList)")
        (ins "(Call Cons)")
        (ins "(MovMemLR GObList EAX)")
        (emit-static-syms (cdr lst)))))

; One zero-initialised 32-bit cell per user global, addressed as (GV name).
(define (emit-globals lst)
  (if (null? lst)
      #f
      (begin
        (ins "(Align4)")
        (ins-dyn (lambda () (o-str "(Label (GV ") (o-sym (car lst)) (o-str "))")))
        (ins "(Dd (X8 0 0 0 0 0 0 0 0))")
        (emit-globals (cdr lst)))))

; ===========================================================================
; Macro expander (Stage 4). rsc adds a full macro-expansion pass in front of
; sc1's codegen: every top-level form is expanded to the sc1 core language
; (quote if lambda define set! begin let cond and or + application) before it
; is compiled. rsc.scm itself uses NONE of the surface features it adds, so on
; rsc's own source expand is a structural identity -- the self-host fixpoint
; therefore only exercises sc1's proven codegen. The new surface features are
; exercised by a separate corpus of programs.
;
; syntax-rules hygiene approach: when a rule's template is instantiated, every
; template identifier that is (a) not a pattern variable, (b) not a literal,
; and (c) not a "known" name -- a special-form keyword, a primitive, an
; already-defined global, or a macro keyword -- is consistently renamed to a
; fresh symbol for that one expansion. This renames macro-introduced
; temporaries (fixing the classic (or a b) capture case) while letting template
; references to cons/if/let/user-globals resolve to their intended bindings.
; ---------------------------------------------------------------------------
; The ellipsis symbol. Written via string->symbol rather than a bare literal
; because scheme0's bootstrap reader (used only to interpret rsc under
; development) mishandles a leading-dot token; sc1-reader (the real bootstrap
; reader) reads a source "..." to the identically interned symbol.
(define ell-sym (string->symbol "..."))

(define keyword-list
  (cons ell-sym
    '(quote quasiquote unquote unquote-splicing if lambda define set! begin
      let cond else and or => let* letrec letrec* case when unless do delay
      define-syntax let-syntax letrec-syntax syntax-rules apply)))

; Fresh-symbol generator for hygiene renaming and expander temporaries.
; Names are %g1, %g2, ... -- % cannot start an identifier in user source, so
; they cannot collide with it.  The counter is deterministic per compilation,
; keeping macro-using builds reproducible (and the fixpoint byte-identical).
(define gensym-counter 0)
(define (num->chars n)
  (if (= n 0) (list #\0) (num->chars-loop n '())))
(define (num->chars-loop n acc)
  (if (= n 0)
      acc
      (num->chars-loop (quotient n 10)
                       (cons (integer->char (+ 48 (remainder n 10))) acc))))
(define (gensym)
  (set! gensym-counter (+ gensym-counter 1))
  (string->symbol (list->string (cons #\% (cons #\g (num->chars gensym-counter))))))

; Compile-time macro environment: assoc name -> (sr <literals> <rules>).
(define macro-env '())
(define defined-globals '())
(define (register-defined name)
  (if (memq name defined-globals) #f (set! defined-globals (cons name defined-globals))))
; The "known" set drives the hygiene heuristic: a template identifier that is
; known resolves to its intended binding and is left alone; anything else is
; assumed to be a macro-introduced temporary and renamed.  Documented
; limitation: a temporary that happens to collide with a LATER-defined user
; global is treated as a reference to it, not renamed.
(define (known-id? id)
  (or (memq id keyword-list)
      (memq id prim-names)
      (memq id defined-globals)
      (if (assq id macro-env) #t #f)))

; --- syntax-rules matcher. A binding node is (leaf . datum) | (ell . nodes) --
; sr-match returns an assoc list (var . node) on success, the symbol 'no on
; failure (never confusable with a binding list, which is () or pairs).
; Per R5RS 4.3.2: `_` matches anything and binds nothing; a literal matches
; only itself; any other symbol is a pattern variable and matches anything;
; a pattern (p ... . tail) matches when some split of the input lets p match
; each leading element and tail match the rest.
(define (pattern-var? x lits)
  (and (symbol? x) (not (eq? x '_)) (not (eq? x ell-sym)) (not (memq x lits))))

(define (sr-match pat inp lits)
  (cond ((eq? pat '_) '())
        ((symbol? pat)
         (if (memq pat lits)
             (if (eq? inp pat) '() 'no)
             (list (cons pat (cons 'leaf inp)))))
        ((null? pat) (if (null? inp) '() 'no))
        ((pair? pat)
         (if (and (pair? (cdr pat)) (eq? (cadr pat) ell-sym))
             (sr-match-ellipsis (car pat) (cddr pat) inp lits)
             (if (pair? inp)
                 (let ((mh (sr-match (car pat) (car inp) lits)))
                   (if (eq? mh 'no)
                       'no
                       (let ((mt (sr-match (cdr pat) (cdr inp) lits)))
                         (if (eq? mt 'no) 'no (append2 mh mt)))))
                 'no)))
        (else (if (eq? pat inp) '() 'no))))

; Minimum number of list elements the pattern after an ellipsis still needs;
; the ellipsis greedily takes everything else.  Since at most one ellipsis
; can appear per list level, this split is unambiguous -- no backtracking.
(define (pat-min-len p)
  (cond ((pair? p)
         (if (and (pair? (cdr p)) (eq? (cadr p) ell-sym))
             (pat-min-len (cddr p))
             (+ 1 (pat-min-len (cdr p)))))
        (else 0)))

(define (take l k) (if (= k 0) '() (cons (car l) (take (cdr l) (- k 1)))))
(define (drop l k) (if (= k 0) l (drop (cdr l) (- k 1))))
(define (nth l i) (if (= i 0) (car l) (nth (cdr l) (- i 1))))

; Match (subpat ... . tailpat) against inp: the first ilen-tlen elements each
; match subpat (collecting one binding list per element), the remainder
; matches tailpat.  transpose-binds then flips the per-element lists into one
; (var . (ell . nodes)) binding per pattern variable of subpat, so that
; instantiation can iterate them in step.
(define (sr-match-ellipsis subpat tailpat inp lits)
  (let ((tlen (pat-min-len tailpat)) (ilen (length inp)))
    (if (< ilen tlen)
        'no
        (let ((k (- ilen tlen)))
          (let ((taken (take inp k)) (rest (drop inp k)))
            (let ((subs (match-each subpat taken lits)))
              (if (eq? subs 'no)
                  'no
                  (let ((mt (sr-match tailpat rest lits)))
                    (if (eq? mt 'no)
                        'no
                        (append2 (transpose-binds subpat subs lits) mt))))))))))

(define (match-each subpat elts lits)
  (if (null? elts)
      '()
      (let ((m (sr-match subpat (car elts) lits)))
        (if (eq? m 'no)
            'no
            (let ((r (match-each subpat (cdr elts) lits)))
              (if (eq? r 'no) 'no (cons m r)))))))

(define (pattern-vars pat lits)
  (cond ((pattern-var? pat lits) (list pat))
        ((pair? pat)
         (if (eq? (car pat) ell-sym)
             (pattern-vars (cdr pat) lits)
             (append2 (pattern-vars (car pat) lits) (pattern-vars (cdr pat) lits))))
        (else '())))

(define (transpose-binds subpat subs lits)
  (map1 (lambda (v) (cons v (cons 'ell (map1 (lambda (sm) (cdr (assq v sm))) subs))))
        (pattern-vars subpat lits)))

; --- template instantiation with per-expansion hygiene renaming --------------
; rename-map is reset for each expansion (see sr-try), so one expansion
; renames an identifier consistently everywhere it occurs, while two
; different expansions of the same macro get distinct fresh names -- the
; property that makes (or a (or b c)) style nesting safe.
(define rename-map '())
(define (rename id)
  (let ((e (assq id rename-map)))
    (if e
        (cdr e)
        (let ((g (gensym)))
          (set! rename-map (cons (cons id g) rename-map))
          g))))

(define (node-datum n) (cdr n))   ; leaf node -> datum

; Instantiate a template: a symbol is a pattern variable (substitute its
; datum), a known identifier (keep), or a macro temporary (rename).  A
; (sub ... . rest) template splices the iterated instances of sub.
(define (sr-inst tmpl binds lits)
  (cond ((symbol? tmpl)
         (let ((b (assq tmpl binds)))
           (if b
               (node-datum (cdr b))
               (if (known-id? tmpl) tmpl (rename tmpl)))))
        ((pair? tmpl)
         (if (and (pair? (cdr tmpl)) (eq? (cadr tmpl) ell-sym))
             (append2 (sr-inst-ellipsis (car tmpl) binds lits)
                      (sr-inst (cddr tmpl) binds lits))
             (cons (sr-inst (car tmpl) binds lits)
                   (sr-inst (cdr tmpl) binds lits))))
        (else tmpl)))

(define (syms-of x)
  (cond ((symbol? x) (list x))
        ((pair? x) (append2 (syms-of (car x)) (syms-of (cdr x))))
        (else '())))
(define (ell-vars sub binds)
  (filter-ell (syms-of sub) binds))
(define (filter-ell syms binds)
  (cond ((null? syms) '())
        ((ell-bound? (car syms) binds) (cons (car syms) (filter-ell (cdr syms) binds)))
        (else (filter-ell (cdr syms) binds))))
(define (ell-bound? v binds)
  (let ((b (assq v binds)))
    (and b (eq? (car (cdr b)) 'ell))))

; Iterate an ellipsis template: find the ellipsis-bound variables that occur
; in sub, take the repetition count from the first one, and instantiate sub
; once per index with each such variable rebound to its i-th node.  (Counts
; are taken to agree; R5RS leaves mismatches unspecified.)  A sub with no
; ellipsis variables produces nothing.
(define (sr-inst-ellipsis sub binds lits)
  (let ((evars (ell-vars sub binds)))
    (if (null? evars)
        '()
        (sr-inst-iter sub binds lits evars (length (cdr (cdr (assq (car evars) binds)))) 0))))
(define (sr-inst-iter sub binds lits evars n i)
  (if (= i n)
      '()
      (cons (sr-inst sub (subst-evars evars binds i) lits)
            (sr-inst-iter sub binds lits evars n (+ i 1)))))
(define (subst-evars evars binds i)
  (if (null? evars)
      binds
      (subst-evars (cdr evars)
                   (cons (cons (car evars) (nth (cdr (cdr (assq (car evars) binds))) i)) binds)
                   i)))

; Try the rules in order; the first whose pattern matches wins.  The
; pattern's own head is ignored ((cdr pat) vs (cdr form)) -- the keyword
; position matches by construction.
(define (sr-expand rules lits form)
  (sr-try rules lits form))
(define (sr-try rules lits form)
  (if (null? rules)
      (error 'macro "no matching syntax-rules clause")
      (let ((pat (car (car rules))) (tmpl (cadr (car rules))))
        (let ((m (sr-match (cdr pat) (cdr form) lits)))
          (if (eq? m 'no)
              (sr-try (cdr rules) lits form)
              (begin (set! rename-map '())
                     (sr-inst tmpl m lits)))))))

; --- quasiquote -> core (list/cons/append/quote) -----------------------------
; The standard depth transform (R5RS 4.2.6): depth counts quasiquote nesting;
; an unquote at depth 1 is live code, deeper ones are re-quoted as data with
; the depth adjusted; ,@ at depth 1 splices via append.  The result uses only
; cons/list/append, which the rsc prelude provides.
(define (qq x depth)
  (cond ((not (pair? x)) (list 'quote x))
        ((eq? (car x) 'unquote)
         (if (= depth 1)
             (cadr x)
             (list 'list (list 'quote 'unquote) (qq (cadr x) (- depth 1)))))
        ((eq? (car x) 'quasiquote)
         (list 'list (list 'quote 'quasiquote) (qq (cadr x) (+ depth 1))))
        ((and (pair? (car x)) (eq? (car (car x)) 'unquote-splicing) (= depth 1))
         (list 'append (cadr (car x)) (qq (cdr x) depth)))
        (else (list 'cons (qq (car x) depth) (qq (cdr x) depth)))))

; --- the expander ------------------------------------------------------------
(define (macro-form? x)
  (and (pair? x) (symbol? (car x)) (if (assq (car x) macro-env) #t #f)))

; expand rewrites one form to the sc1 core language.  Macro uses re-expand
; until the result is no longer a macro form; core special forms recurse into
; their subexpressions (never into a quote); the derived forms below rewrite
; to core and re-expand.  Everything else is an application: expand each part.
(define (expand form)
  (cond
    ((not (pair? form)) form)
    ((eq? (car form) 'quote) form)
    ((macro-form? form)
     (let ((desc (cdr (assq (car form) macro-env))))
       (expand (sr-expand (caddr desc) (cadr desc) form))))
    ((eq? (car form) 'quasiquote) (expand (qq (cadr form) 1)))
    ((eq? (car form) 'lambda)
     (cons 'lambda (cons (cadr form) (map1 expand (cddr form)))))
    ((eq? (car form) 'define) (expand-define form))
    ((eq? (car form) 'define-syntax) (install-define-syntax form) (list 'begin))
    ((eq? (car form) 'let-syntax) (expand-let-syntax form))
    ((eq? (car form) 'letrec-syntax) (expand-let-syntax form))
    ((eq? (car form) 'set!) (list 'set! (cadr form) (expand (caddr form))))
    ((eq? (car form) 'if) (cons 'if (map1 expand (cdr form))))
    ((eq? (car form) 'begin) (cons 'begin (map1 expand (cdr form))))
    ((eq? (car form) 'let) (expand-let form))
    ((eq? (car form) 'cond)
     (if (cond-has-arrow? (cdr form))
         (expand (cond->core (cdr form)))
         (cons 'cond (map1 expand-clause (cdr form)))))
    ((eq? (car form) 'and) (cons 'and (map1 expand (cdr form))))
    ((eq? (car form) 'or) (cons 'or (map1 expand (cdr form))))
    ; Derived special forms, expanded to core by direct transform. (The
    ; syntax-rules engine above is exercised by user macros; these built-ins
    ; are transforms so rsc.scm's source stays free of literal ellipsis.)
    ((eq? (car form) 'when)
     (expand (list 'if (cadr form) (cons 'begin (cddr form)) #f)))
    ((eq? (car form) 'unless)
     (expand (list 'if (cadr form) #f (cons 'begin (cddr form)))))
    ((eq? (car form) 'let*) (expand (let*->core (cadr form) (cddr form))))
    ((eq? (car form) 'letrec) (expand (letrec->core form)))
    ((eq? (car form) 'letrec*) (expand (letrec->core form)))
    ((eq? (car form) 'case) (expand (case->core form)))
    ((eq? (car form) 'do) (expand (do->core form)))
    (else (map1 expand form))))

(define (let*->core binds body)
  (if (null? binds)
      (cons 'let (cons '() body))
      (list 'let (list (car binds)) (let*->core (cdr binds) body))))

; letrec as let-then-set!: bind every name to #f, then assign the inits in
; order.  Adequate here because this dialect has no call/cc and the inits in
; the ladder's sources are lambdas; letrec* is the same transform (its
; left-to-right init order is exactly what we do anyway).
(define (letrec->core form)
  (let ((binds (cadr form)) (body (cddr form)))
    (cons 'let
          (cons (map1 (lambda (b) (list (car b) #f)) binds)
                (append2 (map1 (lambda (b) (list 'set! (car b) (cadr b))) binds)
                         body)))))

; case: evaluate the key once into a gensym temp, then cond over memv tests
; (R5RS says eqv? comparison, hence memv not memq).
(define (case->core form)
  (let ((g (gensym)))
    (list 'let (list (list g (cadr form)))
          (cons 'cond (map1 (lambda (cl) (case-clause g cl)) (cddr form))))))
(define (case-clause g cl)
  (if (eq? (car cl) 'else)
      (cons 'else (cdr cl))
      (cons (list 'memv g (list 'quote (car cl))) (cdr cl))))

; do: the classic named-let loop -- bind the variables, test the exit
; condition, run the commands, recur with each variable's step (or the
; variable itself when no step is given).
(define (do->core form)
  (let ((specs (cadr form)) (exit (caddr form)) (cmds (cdddr form)) (loop (gensym)))
    (list 'let loop
          (map1 (lambda (s) (list (car s) (cadr s))) specs)
          (list 'if (car exit)
                (cons 'begin (if (null? (cdr exit)) (list #f) (cdr exit)))
                (cons 'begin
                      (append2 cmds
                               (list (cons loop (map1 do-step specs)))))))))
(define (do-step s) (if (null? (cddr s)) (car s) (caddr s)))

(define (expand-define form)
  (let ((target (cadr form)))
    (if (pair? target)
        (cons 'define (cons target (map1 expand (cddr form))))
        (if (null? (cddr form))
            form
            (list 'define target (expand (caddr form)))))))

(define (expand-let form)
  (if (symbol? (cadr form))
      (expand (named-let->core form))
      (cons 'let
            (cons (map1 (lambda (b) (list (car b) (expand (cadr b)))) (cadr form))
                  (map1 expand (cddr form))))))

; Named let without letrec: allocate the binding by applying a one-parameter
; lambda to a dummy, tie the knot with set! (the loop lambda sees `name` in
; its captured frame), and return the closure; the outer application then
; calls it with the initial values.
(define (named-let->core form)
  (let ((name (cadr form)) (binds (caddr form)) (body (cdddr form)))
    (cons (list (list 'lambda (list name)
                      (list 'set! name (cons 'lambda (cons (map1 car binds) body)))
                      name)
                #f)
          (map1 cadr binds))))

(define (expand-clause cl)
  (if (eq? (car cl) 'else)
      (cons 'else (map1 expand (cdr cl)))
      (cons (expand (car cl)) (map1 expand (cdr cl)))))

; cond with => needs a rewrite (the test value feeds the receiver, evaluated
; once via a gensym temp); plain cond passes through to the codegen's own
; cond->if untouched, so cond-has-arrow? probes for => first.
(define (cond-has-arrow? clauses)
  (cond ((null? clauses) #f)
        ((and (pair? (cdr (car clauses))) (eq? (cadr (car clauses)) '=>)) #t)
        (else (cond-has-arrow? (cdr clauses)))))
(define (cond->core clauses)
  (if (null? clauses)
      #f
      (let ((cl (car clauses)))
        (cond ((eq? (car cl) 'else) (cons 'begin (cdr cl)))
              ((and (pair? (cdr cl)) (eq? (cadr cl) '=>))
               (let ((g (gensym)))
                 (list 'let (list (list g (car cl)))
                       (list 'if g (list (caddr cl) g) (cond->core (cdr clauses))))))
              ((null? (cdr cl)) (list 'or (car cl) (cond->core (cdr clauses))))
              (else (list 'if (car cl) (cons 'begin (cdr cl)) (cond->core (cdr clauses))))))))

(define (parse-transformer spec)   ; (syntax-rules (lits) rule ...)
  (list 'sr (cadr spec) (cddr spec)))
(define (install-define-syntax form)
  (set! macro-env (cons (cons (cadr form) (parse-transformer (caddr form))) macro-env)))
(define (install-syntax-list binds)
  (if (null? binds)
      #f
      (begin (set! macro-env
                   (cons (cons (car (car binds)) (parse-transformer (cadr (car binds)))) macro-env))
             (install-syntax-list (cdr binds)))))
; let-syntax / letrec-syntax: install the transformers, expand the body, then
; restore the outer macro-env (scoped macros).  Both forms get the letrec
; treatment -- the bindings can see each other -- which is a harmless
; superset of let-syntax for the sources in this tree.
(define (expand-let-syntax form)
  (let ((saved macro-env))
    (install-syntax-list (cadr form))
    (let ((r (expand (cons 'begin (cddr form)))))
      (set! macro-env saved)
      r)))


; ---------------------------------------------------------------------------
; Top-level driver: expand each form to core, note its globals, then compile.
; A top-level (begin ...) splices; an empty (begin) (from define-syntax) emits
; nothing.  note-globals feeds defined-globals -- the hygiene "known" set --
; so a macro used after (define f ...) can mention f in its template without
; f getting renamed.
; ---------------------------------------------------------------------------
(define (note-globals e)
  (cond ((not (pair? e)) #f)
        ((eq? (car e) 'define)
         (register-defined (if (pair? (cadr e)) (car (cadr e)) (cadr e))))
        ((eq? (car e) 'begin) (note-globals-list (cdr e)))
        (else #f)))
(define (note-globals-list l)
  (if (null? l) #f (begin (note-globals (car l)) (note-globals-list (cdr l)))))

(define (emit-top e)
  (cond ((not (pair? e)) (compile-expr e '()))
        ((eq? (car e) 'begin) (emit-top-list (cdr e)))
        (else (compile-expr e '()))))
(define (emit-top-list l)
  (if (null? l) #f (begin (emit-top (car l)) (emit-top-list (cdr l)))))

(define (compile-top form)
  (let ((e (expand form)))
    (note-globals e)
    (emit-top e)))

(define (compile-toplevel-loop)
  (let ((form (rd)))
    (if (eof-object? form)
        #f
        (begin (compile-top form) (compile-toplevel-loop)))))

(define (emit-n-parens n)
  (if (= n 0) #f (begin (o-str ")") (emit-n-parens (- n 1)))))

; The output program's shape:
;   (Assemble (Program Start <bss-size> <code chain> ))
; (X8 6 2 0 0 0 0 0 0) is the bss size, 0x62000000 (~1.5 GiB): unlike sc1's
; 256 MiB it must cover everything the rsc runtime's HeapInit brk()s past the
; image -- the 512 MiB host pair heap plus the byte arenas -- so that no hole
; is left for a big allocation burst to fall into (this exact constant fixed
; a GC-era SIGSEGV; see docs/qmes-gc-b11-diagnosis.md).  Startup: init the
; heap, build the primitive closures, intern the static symbols, set the
; empty environment (EBP = '() = 3), run the compiled top level, then exit(0)
; via int 0x80 (EAX=1 is __NR_exit).  After the exit come the procedure
; bodies, InternStatics, the global cells, the static data, and the fixed
; runtime spliced in by the (RuntimeCode (RuntimeData End)) macros of
; rsc-runtime.qf1.
(define (main)
  (o-str "(Assemble (Program Start (X8 6 2 0 0 0 0 0 0) ")
  (ins "(Label Start)")
  (ins "(Call HeapInit)")
  (ins "(Call InitPrims)")
  (ins "(Call InternStatics)")
  (ins "(MovRI EBP (Small 3))")
  (compile-toplevel-loop)
  (ins "(MovRI EAX (Small 1))")
  (ins "(XorRR EBX EBX)")
  (ins "(Int 80)")
  (drain-procs)
  (emit-internstatics)
  (emit-globals user-globals)
  (drain-data)
  (o-str "(RuntimeCode (RuntimeData End))")
  (emit-n-parens ins-count)             ; close every (Ins ... opened above
  (o-str "))")
  (newline)
  (exit 0))

(main)
