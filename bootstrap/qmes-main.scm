; qmes-main.scm — the qmes entry point, deliberately a separate file.
;
; A qmes build is a concatenation compiled as one rsc program:
;   i386:   rsc-prelude.scm + qmes.scm               + qmes-main.scm
;   x86_64: rsc-prelude.scm + qmes.scm + qmes-w64.scm + qmes-main.scm
; rsc compiles top-level defines into ordered startup assignments (last
; define wins for every subsequent call), so the w64 overlay must land
; AFTER qmes.scm and BEFORE anything runs.  Splitting this one call out is
; what creates that slot (docs/qmes.md §8.3); the i386 build simply omits
; the overlay and is byte-identical to the pre-split build.
(qmain)
