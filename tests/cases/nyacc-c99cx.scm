; Exercise regenerated constant-expression actions/tables directly. The optional
; cxeval module also requires a foreign-type ABI and is not used by this test.
(use-modules (nyacc parse) (nyacc lex) (nyacc lang util))
(include-from-path "nyacc/lang/c99/mach.d/c99cx-act.scm")
(include-from-path "nyacc/lang/c99/mach.d/c99cx-tab.scm")
(define parser (make-lalr-parser (acons 'act-v c99cx-act-v c99cx-tables)))
(define comment-reader (make-comm-reader '(("/*" . "*/"))))
(define lexer
  (make-lexer-generator c99cx-mtab
    #:comm-skipper (lambda (char) (comment-reader char #f))
    #:chlit-reader read-c-chlit #:num-reader read-c-num))
(for-each
  (lambda (text)
    (write (with-input-from-string text (lambda () (parser (lexer)))))
    (newline))
  '("1 + 2 * 3" "a ? 4 : 5" "items[2]"))
