; A definition-site reference must not resolve in the caller's scope.
(define g 10)
(define-syntax get-g (syntax-rules () ((_) g)))
(display (let ((g 20)) (get-g)))
(newline)
