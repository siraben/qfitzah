; Pattern strings match by contents, not object identity.
(define-syntax str-case
  (syntax-rules () ((_ "a") 1) ((_ x) 2)))
(display (str-case "a"))
(newline)
