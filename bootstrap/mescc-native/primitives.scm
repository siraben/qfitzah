; Mes's cons* uses this native destructive reverse-with-tail primitive.
(define (core:reverse! items tail)
  (let loop ((items items) (out tail))
    (cond ((null? items) out)
          ((not (pair? items)) (error 'core:reverse! "improper list"))
          (else (let ((next (cdr items)))
                  (set-cdr! items out)
                  (loop next items))))))
