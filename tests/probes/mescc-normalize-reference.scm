; Unmodified pinned Mes transformations are the differential oracle.
(use-modules (mescc preprocess))
(define arguments (cdr (command-line)))
(if (not (= (length arguments) 1)) (error 'normalize-reference "expected input file") #f)
(define ast (call-with-input-file (car arguments) read))
(define module (resolve-module '(mescc preprocess)))
(for-each (lambda (name) (set! ast ((module-ref module name) ast)))
          '(ast-strip-comment ast-strip-const ast-strip-attributes ast-strip-inline))
(write ast) (newline)
