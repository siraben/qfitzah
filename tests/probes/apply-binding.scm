; Parameter assignment must not mutate apply's supplied list.
(define xs (cons 1 (cons 2 '())))
(apply (lambda (a b) (set! a 9)) xs)
(write xs)
(newline)
