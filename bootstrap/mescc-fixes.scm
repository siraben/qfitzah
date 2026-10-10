; Narrow correctness repairs for pinned Mes 0.27.1 in reproducible/Mes mode.
; Originals stay untouched. The M1 linker continues rejecting conflicting labels.
(use-modules (mes misc) (mescc info))
(define fixes-compile (resolve-module '(mescc compile)))
(define fixes-m1 (resolve-module '(mescc M1)))
(define original-global->info (module-ref fixes-compile 'global->info))
(define original-info->M1 (module-ref fixes-m1 'info->M1))
(define fixes-make-comment (module-ref fixes-compile 'make-comment))
; Label IDs use text length. Dropping AST comments entirely lets an outer if
; and a conditional expression in its test claim the same ID. A deterministic
; zero-byte comment reserves a text position before entering nested constructs.
(module-define! fixes-compile 'ast->comment
  (lambda (ast) (fixes-make-comment "")))
(define (fixes-real-global? entry)
  (and entry (not (eq? (global:storage (cdr entry)) 'extern))))
(define (fixes-select-global old new init)
  (cond ((not (fixes-real-global? old)) new)
        ((eq? (global:storage (cdr new)) 'extern) old)
        ((and init (not (null? init))) new)
        ; A later complete array declaration can complete an earlier tentative
        ; incomplete one. Otherwise a tentative declaration preserves the value.
        ((> (length (global:value (cdr new))) (length (global:value (cdr old)))) new)
        (else old)))
(define (fixes-replace-global entries name selected)
  (let loop ((entries entries) (placed? #f))
    (cond ((null? entries) (if placed? '() (list selected)))
          ((equal? (caar entries) name)
           (if placed? (loop (cdr entries) #t)
               (cons selected (loop (cdr entries) #t))))
          (else (cons (car entries) (loop (cdr entries) placed?))))))
(module-define! fixes-compile 'global->info
  (lambda (storage type name ast init info)
    (let* ((old (assoc name (.globals info)))
           ; An initialized extern is a definition, not an unresolved import.
           (storage (if (and (eq? storage 'extern) init (not (null? init))) #f storage))
           (result (original-global->info storage type name ast init info))
           (new (last (.globals result)))
           (selected (fixes-select-global old new init)))
      (if (eq? storage 'typedef)
          ; Upstream's function-pointer typedef fallback builds a global. Move
          ; its type into the type namespace so later typename uses also work.
          (clone result #:globals (.globals info)
                 #:types (acons name (global:type (cdr new)) (.types result)))
          (clone result #:globals (fixes-replace-global (.globals result) name selected))))))
; Repeated function-local strings can reach the writer under identical keys.
; Their pooled labels must have exactly one definition, independent of uses.
(define (fixes-unique-strings globals)
  (let loop ((rest globals) (seen '()))
    (if (null? rest) '()
        (let* ((entry (car rest)) (key (car entry))
               (string? (and (pair? key) (eq? (car key) #:string))))
          (if (and string? (member key seen)) (loop (cdr rest) seen)
              (cons entry (loop (cdr rest) (if string? (cons key seen) seen))))))))
; Function-pointer typedefs fall through upstream's generic declaration path
; into .globals. Keep their compile-time metadata, but never allocate storage.
(define (fixes-object-global? entry)
  (not (eq? (global:storage (cdr entry)) 'typedef)))
(module-define! fixes-m1 'info->M1
  (lambda (file info . options)
    (apply original-info->M1 file
      (clone info #:globals
        (fixes-unique-strings (filter fixes-object-global? (.globals info)))) options)))
