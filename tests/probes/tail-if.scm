; Control for the same low-stack environment as tail-or.
(define (loop n) (if (= n 0) #t (loop (- n 1))))
(write (loop 50000))
(newline)
