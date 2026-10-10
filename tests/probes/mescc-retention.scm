; Diagnostic: repeat the same real C frontend, dropping each result, and
; observe post-collection retained space rather than inferring it from RSS.
(use-modules (mescc compile) (mescc i386 info))
(define (report label)
  (write (list label 'live-eight-byte-units (%gc-live-units) 'gc (gc-count)))
  (newline))
(define program "int f(int x) { return x + 1; } int main(void) { return f(41); }\n")
(report 'loaded)
(let loop ((i 1))
  (if (> i 20) #t
      (begin
        (with-input-from-string program (lambda () (c99-input->info (x86-info))))
        (report i)
        (loop (+ i 1)))))
