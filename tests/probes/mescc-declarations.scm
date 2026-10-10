; Diagnostic loaded before mescc.scm when replaying a completed .E checkpoint.
; Trace only translation-unit children, not recursive expression compilation.
(use-modules (mescc compile))
(define compile-module (resolve-module '(mescc compile)))
(define original-ast->info (module-ref compile-module 'ast->info))
(define declaration-depth 0)
(define declaration-index 0)
(module-define! compile-module 'ast->info
  (lambda (ast info)
    (set! declaration-depth (+ declaration-depth 1))
    (let ((top? (= declaration-depth 2)))
      (if top?
          (begin
            (display "declaration ") (write declaration-index) (display " begin ")
            (if (and (>= declaration-index 560) (pair? ast) (eq? (car ast) 'decl))
                (write ast) (write (if (pair? ast) (car ast) ast)))
            (newline)) #f)
      (let ((result (original-ast->info ast info)))
        (if top?
            (begin (display "declaration ") (write declaration-index)
                   (display " done\n")
                   (set! declaration-index (+ declaration-index 1))) #f)
        (set! declaration-depth (- declaration-depth 1))
        result))))
