; Requires --mes: syntax-rules itself is compiled from pinned Mes source.
(define-syntax matrix
  (syntax-rules () ((_ ((x ...) ...)) (list (list x ...) ...))))
(write (matrix ((1 2) (3 4 5)))) (newline)
(define-syntax swap!
  (syntax-rules () ((_ a b) (let ((temp a)) (set! a b) (set! b temp)))))
(write (let ((temp 1) (other 2)) (swap! temp other) (list temp other))) (newline)
(define-syntax literal
  (syntax-rules (needle) ((_ needle) 'yes) ((_ other) 'no)))
(write (list (literal needle) (let ((needle #f)) (literal needle)))) (newline)
(define-syntax quoted-vector
  (syntax-rules () ((_ #(x ...)) '#(x ...))))
(write (quoted-vector #(a b c))) (newline)
(define-syntax-rule (make-keyword) #:hello)
(write (make-keyword)) (newline)
(use-modules (example macros))
(define (private-helper x) 'wrong-helper)
(write (add-secret 2)) (newline)
(write (quoted-name 'sample)) (newline)
(write (letrec-syntax ((last (syntax-rules () ((_ x) x) ((_ x y ...) (last y ...)))))
         (last 1 2 3))) (newline)
(write '(. rest)) (newline)
(write (map char->integer (string->list "\x07\x08\e\0"))) (newline)
(write (char->integer (string-ref (read (open-input-string "\"\\x07;\"")) 0))) (newline)
(write (if #f 1 2 (error "Mes ignores additional alternatives"))) (newline)
(use-modules ((srfi srfi-1) #:select (fold)))
(write (fold (lambda (a b sum) (+ a b sum)) 0 '(1 2) '(10 20))) (newline)
; Compiler-phase helpers must not be captured by interaction bindings.
(define map #f)
(define member #f)
(define-syntax after-shadow (syntax-rules () ((_ x) (list x))))
(write (after-shadow 7)) (newline)
