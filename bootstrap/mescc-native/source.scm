; Extract original pinned Mes definitions; do not substitute new AST semantics.
; Run with the source-built Mes host. Leading upstream notices are preserved.
(define arguments (cdr (command-line)))
(if (not (= (length arguments) 1)) (error 'native-normalizer "expected Mes source directory") #f)
(define mes-source (car arguments))
(define (definition-name form)
  (and (pair? form) (memq (car form) '(define define-syntax))
       (pair? (cdr form))
       (let ((head (cadr form))) (if (pair? head) (car head) head))))
(define (source-read-line)
  (let loop ((chars '()))
    (let ((c (read-char)))
      (cond ((eof-object? c) (if (null? chars) c (list->string (reverse chars))))
            ((char=? c #\newline) (list->string (reverse chars)))
            (else (loop (cons c chars)))))))
(define (copy-notices path)
  (with-input-from-file path
    (lambda ()
      (let loop ((line (source-read-line)))
        (if (or (eof-object? line) (string-prefix? "(" line)) #t
            (begin (display line) (newline) (loop (source-read-line))))))))
(define (extract relative names)
  (let ((path (string-append mes-source "/" relative)) (found '()))
    (display "; Original definitions from GNU Mes: ") (display relative) (newline)
    (copy-notices path)
    (with-input-from-file path
      (lambda ()
        (let loop ((form (read)))
          (if (eof-object? form) #t
              (let ((name (definition-name form)))
                (if (memq name names)
                    (begin
                      (if (memq name found) (error 'native-normalizer "duplicate source definition" name) #f)
                      (set! found (cons name found))
                      (write form) (newline)) #f)
                (loop (read)))))))
    (for-each (lambda (name) (if (not (memq name found))
                               (error 'native-normalizer "missing source definition" name) #f)) names)))
(extract "mes/module/mes/boot-0.scm" '(cons*))
(extract "mes/module/mes/base.mes" '(list?))
(extract "mes/module/srfi/srfi-1.mes" '(filter-map))
(extract "mes/module/system/base/pmatch.scm" '(pmatch ppat))
(extract "module/mescc/preprocess.scm"
         '(ast-strip-comment qual-const? ast-strip-attributes ast-strip-inline ast-strip-const))
