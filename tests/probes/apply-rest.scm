; Rest-parameter binding must not mutate the supplied list spine.
(define xs (cons 1 (cons 2 (cons 3 '()))))
(apply (lambda (a . rest) #f) xs)
(write xs)
(newline)
