; Run with only freshly regenerated parser tables on the Nyacc load path.
(use-modules (nyacc lang c99 cpp))
(write (parse-cpp-expr "1 + 2 * 3")) (newline)
(for-each
  (lambda (text) (write (eval-cpp-expr (parse-cpp-expr text))) (newline))
  '("1 + 2 * 3" "7 / 2" "-7 / 2" "1 << 40" "32 >> 3"
    "0 ? 9 : 4" "1 || (7 / 0)" "'\\n' == 10" "0xffffffffffffffffULL"))
(write (eval-cpp-cond-text "defined(ANSWER) && ANSWER == 42" '(("ANSWER" . "42")))) (newline)
(write (eval-cpp-cond-text "UNKNOWN + 3")) (newline)
(write (eval-cpp-cond-text "MAX(3, 7)" '(("MAX" ("X" "Y") . "((X)>(Y)?(X):(Y))")))) (newline)
; Stringification escape path used by libc assertions and diagnostic macros.
(write (equal? ((@@ (nyacc lang c99 cpp) esc-c-str)
                 (list->string '(#\a #\" #\\ #\b)))
               (list->string '(#\a #\\ #\" #\\ #\\ #\b)))) (newline)
