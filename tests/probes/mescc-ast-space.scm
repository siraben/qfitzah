; Diagnostic for peak AST-transform space on a broad translation unit. Uses
; actual upstream transformations, but synthetic AST data (not a C-build test).
(use-modules (mescc preprocess))
(define preprocess-module (resolve-module '(mescc preprocess)))
(define declaration
  '(decl (decl-spec-list (type-spec (fixed-type "int")))
         (init-declr-list (init-declr (ident "g")))))
(define (report n name event)
  (write (list n name event 'retained-units (%gc-live-units) 'gc (gc-count)))
  (newline))
(define (transform n name tree)
  (report n name 'begin)
  (let ((result ((module-ref preprocess-module name) tree)))
    (report n name 'done)
    (if (= (length result) (+ n 1)) #t (error 'ast-space "wrong AST length"))))
(for-each
  (lambda (n)
    (let ((tree (cons 'trans-unit (make-list n declaration))))
      (for-each (lambda (name) (transform n name tree))
                '(ast-strip-comment ast-strip-const ast-strip-attributes ast-strip-inline))))
  '(64 128 256 512 1024))
