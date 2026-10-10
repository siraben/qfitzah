(use-modules (nyacc lang c99 pprint))
(write (with-output-to-string
         (lambda ()
           (pretty-print-c99
             '(expr-stmt (add (p-expr (fixed "1"))
                              (mul (p-expr (fixed "2")) (p-expr (fixed "3")))))))))
(newline)
