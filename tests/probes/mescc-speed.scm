; Bounded throughput probe: real upstream AST normalization, no C-build claim.
; Run with the same MES/NYACC roots and QFITZAH_BENCH_SIZE for comparisons.
(use-modules (mescc preprocess))
(define n (string->number (or (getenv "QFITZAH_BENCH_SIZE") "128")))
(define tree
  (cons 'trans-unit
    (make-list n '(decl (decl-spec-list (type-spec (fixed-type "int")))
                       (init-declr-list (init-declr (ident "g")))))))
(define start-gc (gc-count))
(for-each
  (lambda (name)
    (let ((result ((module-ref (resolve-module '(mescc preprocess)) name) tree)))
      (if (equal? result tree) #t (error 'mescc-speed "changed AST" name))))
  '(ast-strip-comment ast-strip-const ast-strip-attributes ast-strip-inline))
(write (list 'normalized n 'collections (- (gc-count) start-gc))) (newline)
(if (defined? '%analyzer-counts)
    (begin (display "analyzed/fallback transformers: ")
           (write (%analyzer-counts)) (newline)) #f)
