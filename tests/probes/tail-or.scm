; The final operand of or is in tail position.
(define (loop n) (or (= n 0) (loop (- n 1))))
(write (loop 50000))
(newline)
