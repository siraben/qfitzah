; Run with analyzed transformers enabled AND disabled, and compare exactly.
(define-syntax columns
  (syntax-rules ()
    ((_ ((a b) ...)) (list (list a ...) (list b ...)))))
(write (columns ((1 2) (3 4) (5 6)))) (newline)
(define-syntax nested
  (syntax-rules () ((_ ((v ...) ...)) (list (list v ...) ...))))
(write (nested ((1 2) () (3)))) (newline)
(define-syntax vector-match
  (syntax-rules () ((_ #(a b)) (list b a))))
(write (vector-match #(7 8))) (newline)
(define-syntax dotted
  (syntax-rules () ((_ (a . b)) (quote (a . b)))))
(write (dotted (left . right))) (newline)
(define-syntax literal-binding
  (syntax-rules (marker)
    ((_ marker) 'same)
    ((_ other) 'different)))
(write (literal-binding marker)) (newline)
(write (let ((marker 42)) (literal-binding marker))) (newline)
; Newly created local syntax captures the current activation, not the first.
(define (capture value)
  (let-syntax ((read-value (syntax-rules () ((_ ignored) (+ value 1)))))
    (read-value ignored)))
(write (list (capture 40) (capture 99))) (newline)
(define count 0)
(define-syntax hygienic-once
  (syntax-rules () ((_ expression) (let ((temp expression)) (list temp temp)))))
(write (let ((temp 77))
         (hygienic-once (begin (set! count (+ count 1)) temp)))) (newline)
(write count) (newline)
(write (catch #t (lambda () (eval '(columns ((1 2 3)))) #f)
                (lambda args #t))) (newline)
(let ((counts (%analyzer-counts)))
  (if (> (if (getenv "QFITZAH_DISABLE_ANALYSIS") (cadr counts) (car counts)) 0)
      (display "ok - transformer execution mode exercised\n")
      (error 'analyzer "requested path not exercised" counts)))
