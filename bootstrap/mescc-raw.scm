; Internal frontend-only mode for a separately source-built native normalizer.
; The ordinary -S restriction still applies. No backend or external tool runs.
(define raw-ast-path (getenv "QFITZAH_MESCC_RAW_AST_OUTPUT"))
(define raw-ast-marker (string-append raw-ast-path ".complete"))
(if (or (file-exists? raw-ast-path) (file-exists? raw-ast-marker))
    (error 'mescc "raw AST destination already exists" raw-ast-path) #f)
(define raw-preprocess-module (resolve-module '(mescc preprocess)))
(define raw-frontend (module-ref raw-preprocess-module 'c99-input->full-ast))
(module-define! raw-preprocess-module 'c99-input->ast
  (lambda arguments
    (let ((ast (apply raw-frontend arguments)))
      (if (not (and (pair? ast) (eq? (car ast) 'trans-unit)))
          (error 'mescc "invalid raw translation unit") #f)
      (with-output-to-file raw-ast-path (lambda () (write ast) (newline)))
      (with-output-to-file raw-ast-marker
        (lambda () (display "qfitzah-mescc-raw-ast-v1\n")))
      (exit 0))))
