(define (read-all p)
  (let ((datum (read p)))
    (if (eof-object? datum) #t
        (begin
          ; Exercise the writer's escaping and the reader's inverse together.
          (let* ((text (call-with-output-string (lambda (out) (write datum out))))
                 (again (read (open-input-string text))))
            (if (equal? datum again) #t (error 'reader "roundtrip mismatch" text)))
          (write datum) (newline)
          (read-all p)))))
(read-all (current-input-port))
(for-each
  (lambda (s)
    (write (catch 'misc-error
             (lambda () (read (open-input-string s)) 'incorrectly-accepted)
             (lambda args 'rejected)))
    (newline))
  '("(" "[)" "(. x)" "(a . b c)" "'" "#;" "#| unclosed" "#z"
    "#(a . b)" "#\\unknown" "#\\x100" "\"unclosed" "|unclosed"))
(write (keyword? (symbol->keyword 'hello))) (newline)
(write (keyword->symbol (read (open-input-string "#:hello")))) (newline)
