(define-module (example macros) #:export (add-secret quoted-name))
(define secret 40)
(define (private-helper x) (+ secret x))
(define-syntax add-secret
  (syntax-rules () ((_ x) (private-helper x))))
(define-syntax quoted-name
  (syntax-rules (quote)
    ((_ (quote x)) 'x)
    ((_ x) 'wrong-literal-binding)))
