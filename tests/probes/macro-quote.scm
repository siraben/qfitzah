; Quoted data in a macro template must retain its spelling.
(define-syntax hello-m (syntax-rules () ((_) 'hello)))
(write (hello-m))
(newline)
