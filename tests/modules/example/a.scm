(define-module (example a) #:export (a from-b) #:use-module (example b))
(define a 1)
(define (from-b) (list b (get-a)))
