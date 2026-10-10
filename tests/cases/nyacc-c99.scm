; Execute both regenerated full-C and full-expression grammars.
(use-modules (nyacc lang c99 parser) (nyacc lang c99 pprint))
(define tree
  (with-input-from-string "#define VALUE 42\nint n = VALUE;\n"
    (lambda () (parse-c99))))
(if (not (and (pair? tree) (eq? (car tree) 'trans-unit)))
    (error 'nyacc-c99 "translation unit not parsed") #f)
(write (with-output-to-string (lambda () (pretty-print-c99 tree)))) (newline)
(write (parse-c99x "1 + 2 * 3")) (newline)
