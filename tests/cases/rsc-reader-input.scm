#! ignored interpreter line
  ignored switches
!#
; Line comments and recursively nested datum/block comments.
#| outer #| inner |# outer |#
#; (ignored #; 123 datum)
(1 +2 -3 #xff #o77 #b101 #d42 #e#x100)
18446744073709551616
#(a (b . c) "line\nquote\"slash\\" #t #false)
[alpha beta . gamma]
'quoted `(+ ,x ,@xs)
#'syntax-datum #`(x #,y #,@z)
#\space #\newline #\tab #\return #\x41 #\) #\(
"a\x00;b\r\t"
|a b| |a\|b| |.| #:key
(... + - .identifier)
