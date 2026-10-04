; syntax-rules literal matching is binding-sensitive.
(define-syntax classify
  (syntax-rules (tag) ((_ tag) 1) ((_ x) 2)))
(display (let ((tag 0)) (classify tag)))
(newline)
