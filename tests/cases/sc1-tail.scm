; Deep tail loop: one million iterations must run in constant machine stack.
(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc 1))))
(display (loop 1000000 0)) (newline)
