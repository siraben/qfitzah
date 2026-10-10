; Internal coordination for mescc-native.sh, using upstream's parsed options.
; Preserve its input/output naming and option handling; never reparse argv here.
(define native-phase (getenv "QFITZAH_MESCC_NATIVE_PHASE"))
(define native-script-root (dirname (car arguments)))
(define native-module (resolve-module '(mescc mescc)))
(define native-compile (module-ref native-module 'mescc:compile))
(define native-option-ref (module-ref native-module 'option-ref))
(define native-e->info (module-ref native-module 'E->info))
(define (native-single-c? options)
  (let ((files (native-option-ref options '() '("a.c"))))
    (and (pair? files) (null? (cdr files)) (string-suffix? ".c" (car files)))))
(define (native-check-destination path)
  (if (and path (or (file-exists? path) (file-exists? (string-append path ".complete"))))
      (error 'mescc "AST checkpoint destination already exists" path) #f))
(module-define! native-module 'mescc:compile
  (lambda (options)
    (cond
      ((string=? native-phase "frontend")
       (if (native-single-c? options)
           (begin
             (native-check-destination (getenv "QFITZAH_MESCC_AST_OUTPUT"))
             (load (string-append native-script-root "/mescc-raw.scm"))
             (native-compile options))
           (let ((result (native-compile options)))
             ; AST replay and other upstream-supported shapes need no filter.
             (with-output-to-file (getenv "QFITZAH_MESCC_NATIVE_BYPASS")
               (lambda () (display "qfitzah-mescc-native-bypass-v1\n")))
             result)))
      ((string=? native-phase "backend")
       (if (not (native-single-c? options)) (error 'mescc "native backend expects one C input") #f)
       (let ((path (getenv "QFITZAH_MESCC_NORMALIZED_AST")))
         (module-define! native-module 'c->info
           (lambda (options source) (native-e->info options path)))
         (native-compile options)))
      (else (error 'mescc "invalid native compilation phase" native-phase)))))
