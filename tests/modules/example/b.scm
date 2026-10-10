(define-module (example b) #:export (b get-a) #:use-module (example a))
(define b 2)
(define (get-a) a)
