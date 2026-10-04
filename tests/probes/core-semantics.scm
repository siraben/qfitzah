; Valid programs beyond the self-hosting compiler's exercised subset.
; Expected output is the intended Scheme semantics, not the current bugs.
(display 134217728) (newline)
(display '134217728) (newline)
(define x 1)
(display ((lambda () (define x 2) x))) (newline)
(display x) (newline)
(write (cond (7) (else 9))) (newline)
(write (= 1 1 2)) (newline)
(write (< 1 2 0)) (newline)
(write "a\"b\\c") (newline)
