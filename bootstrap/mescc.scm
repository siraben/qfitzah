; Restricted entry point: MesCC emits M1; our source-built tool links it.
; Never enter upstream's system* wrappers for host M1/hex2/ar programs.
(define arguments (command-line))
(if (not (member "-S" arguments))
    (error 'mescc "this bootstrap driver requires -S") #f)
(use-modules (mescc))
; Check the selected operation too: a literal "-S" could be an option operand
; or follow "--". Shared import cells make these guards visible to mescc:main.
(define (unsupported-operation . args)
  (error 'mescc "only compilation to M1 is enabled by this driver"))
(for-each
  (lambda (name)
    (module-define! (resolve-module '(mescc mescc)) name unsupported-operation))
  '(mescc:preprocess mescc:assemble mescc:link))
(load (string-append (dirname (car arguments)) "/mescc-fixes.scm"))
(if (getenv "QFITZAH_MESCC_NATIVE_PHASE")
    (load (string-append (dirname (car arguments)) "/mescc-native-stage.scm"))
    (if (getenv "QFITZAH_MESCC_RAW_AST_OUTPUT")
        (load (string-append (dirname (car arguments)) "/mescc-raw.scm")) #f))
(if (getenv "QFITZAH_MESCC_TRACE")
    (load (string-append (dirname (car arguments)) "/mescc-trace.scm")) #f)
(mescc:main arguments)
