; Same bounded declaration tree as mescc-speed.scm, serialized for both paths.
(define n (string->number (or (getenv "QFITZAH_BENCH_SIZE") "128")))
(if (not (and (integer? n) (>= n 0) (<= n 4096)))
    (error 'normalization-benchmark "count must be an integer in 0..4096" n) #f)
(define declaration
  '(decl (decl-spec-list (type-spec (fixed-type "int")))
         (init-declr-list (init-declr (ident "g")))))
(let loop ((left n) (declarations '()))
  (if (= left 0) (begin (write (cons 'trans-unit declarations)) (newline))
      (loop (- left 1) (cons declaration declarations))))
