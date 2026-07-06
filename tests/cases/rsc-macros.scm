; Stage 4 corpus: syntax-rules macros (hygiene, ellipsis, recursion, nesting).
; Self-contained: defines its own helpers (no prelude assumed).
(define (list . xs) xs)

; 1. swap! -- hygiene: the introduced temp must not capture user bindings.
(define-syntax swap!
  (syntax-rules ()
    ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))
(define p 1)
(define q 2)
(swap! p q)
(display "swap: ") (display p) (display " ") (display q) (newline)

; The classic capture case: a user LOCAL named exactly like the macro's temp.
; Hygiene renames the introduced tmp so the user's tmp is not shadowed.
(display "swap-cap: ")
(display (let ((tmp 10) (u 20)) (swap! tmp u) (list tmp u)))
(newline)

; 2. my-or / my-and -- ellipsis + recursion + hygiene of the introduced t.
(define-syntax my-or
  (syntax-rules ()
    ((_) #f)
    ((_ e) e)
    ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
(define-syntax my-and
  (syntax-rules ()
    ((_) #t)
    ((_ e) e)
    ((_ e1 e2 ...) (if e1 (my-and e2 ...) #f))))
(display "my-or: ") (display (my-or #f #f 7 8)) (newline)
(display "my-and: ") (display (my-and 1 2 3)) (newline)
; capture check: user LOCAL t must be seen by my-or, not the introduced temp.
(display "my-or-capture: ") (display (let ((t 42)) (my-or #f t))) (newline)

; 3. my-list -- ellipsis passthrough.
(define-syntax my-list
  (syntax-rules ()
    ((_ x ...) (list x ...))))
(display "my-list: ") (display (my-list 1 2 3 4 5)) (newline)

; 4. my-let -- ellipsis over nested (n v) pairs, two independent ellipsis vars.
(define-syntax my-let
  (syntax-rules ()
    ((_ ((n v) ...) body ...)
     ((lambda (n ...) body ...) v ...))))
(display "my-let: ")
(display (my-let ((a 3) (b 4) (c 5)) (+ a (+ b c))))
(newline)

; 5. recursive ellipsis macro building nested code.
(define-syntax my-begin
  (syntax-rules ()
    ((_ e) e)
    ((_ e1 e2 ...) (let ((ignore e1)) (my-begin e2 ...)))))
(display "my-begin: ") (display (my-begin 1 2 3 99)) (newline)

; 6. let-syntax local macro.
(display "let-syntax: ")
(display (let-syntax ((twice (syntax-rules () ((_ e) (+ e e)))))
          (twice 21)))
(newline)
