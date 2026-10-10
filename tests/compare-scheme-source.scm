; Compare source datums, not whitespace or reader abbreviation choices.
; Reference files are test oracles only: neither input is evaluated here.
(define (compare-source left right)
  (call-with-input-file left
    (lambda (a)
      (call-with-input-file right
        (lambda (b)
          (let loop ((count 0))
            (let ((x (read a)) (y (read b)))
              (cond ((and (eof-object? x) (eof-object? y))
                     (display "equal Scheme forms: ") (write count) (newline))
                    ((or (eof-object? x) (eof-object? y) (not (equal? x y)))
                     (error 'compare-source "different form" count))
                    (else (loop (+ count 1)))))))))))
(let ((arguments (cdr (command-line))))
  (if (= (length arguments) 2) (apply compare-source arguments)
      (error 'compare-source "expected two filenames")))
