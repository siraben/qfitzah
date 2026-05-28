        ## Qfitzah, a leap or shortening: from a kilobyte
        ## or two of i386 machine code to a
        ## higher-order programming language with pattern matching,
        ## flexible parametrically-polymorphic data containers, and
        ## dynamically dispatched method calls with multiple dispatch.

        ## To build:
        ## $ gcc -Wl,-z,noseparate-code -static -m32 -nostdlib qfitzah.s -o qfitzah.bloated
        ## $ objcopy -S -R .note.gnu.build-id qfitzah.bloated qfitzah

        ## This version does *not* use bytecode.  But it should
        ## be a good estimate for how much
        ## code is needed for a Qfitzah (with some primitive operations
        ## such as addition).  358 instructions, 731 bytes of code, 40
        ## bytes of data, 1184 bytes of executable.

        ## (Brian Raiter’s sstrip utility reduced the 1056-byte
        ## version of the executable to 828 bytes, a 228-byte
        ## reduction, but I don’t yet have that built into the build
        ## process.)

        ## The m4 manual says, “An important precursor of m4 was GPM;
        ## see C. Strachey, ‘A general purpose macrogenerator’,
        ## Computer Journal 8, 3 (1965), 225–41,
        ## https://academic.oup.com/comjnl/article/8/3/225/336044. GPM
        ## is also succinctly described in David Gries’s book Compiler
        ## Construction for Digital Computers, Wiley (1971).
        ## ...GPM fit into 250 machine
        ## instructions!”  Well, Qfitzah isn’t quite that small yet,
        ## and it may not get there, but it’s a lot more agreeable to
        ## program in than GPM.

        ## Using variables in a template that are not matched in the
        ## pattern is a bug that the interpreter doesn’t detect,
        ## instead crashing:
        ## ↪ (Do Nothing) no
        ## ↪ (Do Nothing)
        ## Segmentation fault
        ##
        ## Using the same variable more than once is also an unchecked
        ## bug, but doesn’t crash:
        ## ↪ (Eq x x) (Yes x)
        ## ↪ (Eq 3 3)
        ## (Yes 3)
        ## ↪ (Eq 3 4)
        ## (Yes 4)

        ## On calling conventions:

        ## My initial thought was to use the standard i386 Linux ABI
        ## (stemming from Microsoft’s cdecl), where %ebx, %esi, %edi,
        ## %ebp, and of course %eip and %esp are preserved across
        ## calls, but %eax, %ecx, and %edx are not; but since my
        ## objective is to make things as small as possible, it was
        ## immediately obvious that passing all the parameters on the
        ## stack is unacceptably code-bloaty, so I was passing up to
        ## three parameters in %eax, %ecx, and %edx, and getting
        ## return values in %eax, and booleans in the flags.  So,
        ## within some limits, I was free to use %ebx, %esi, %edi, and
        ## %ebp as global variables.  I used %ebx as the allocation
        ## pointer, saving 12 bytes of code in the `cons` function,
        ## %esi as the parsing pointer, and %edi as the pointer to the
        ## global set of rewrite rules.

        ## However, I’ve come to the conclusion that this was a
        ## mistake, and callee-saved registers are generally not
        ## useful for i386 size optimization, especially not these.

        ## If you want to preserve a value across a call, you have two
        ## choices: you can push it on the stack (1 byte to push, one
        ## byte to pop) or you can allocate it in a callee-saved
        ## register.  But that means that you have to save and restore
        ## the callee-saved register at entry and exit, which costs
        ## the same 2 bytes; moreover, if you got the value by calling
        ## another function, you need an additional byte to xchg the
        ## value from %eax into the callee-saved register.  Also,
        ## pushing and popping lets you relocate it to a different
        ## register for free.  In theory using a callee-saved register
        ## could still be a win if you have multiple calls across
        ## which to preserve a value, but so far it never has been.
        ## And you have to weigh this dubious benefit against the
        ## benefit of having fewer registers available for
        ## temporaries: 3 temporaries, shared with arguments, is
        ## pretty cramped!

        ## Moreover, in the 8086, the only registers that could be
        ## used as pointers were %ebx, %ebp, %esi, and %edi; while the
        ## i386 removed this restriction, addressing with those
        ## registers still produces tighter code in some cases (like
        ## lodsb and I think base+index), though not in the simplest
        ## cases:

        ## 804816e:     89 48 04                mov    %ecx,0x4(%eax)
        ## 8048171:     89 4b 04                mov    %ecx,0x4(%ebx)
        ## 804812c:     8b 09                   mov    (%ecx),%ecx
        ## 804832a:     8b 13                   mov    (%ebx),%edx
        ## 804816c:     89 03                   mov    %eax,(%ebx)
        ## 8048358:     89 01                   mov    %eax,(%ecx)
        ## 8048358:     89 07                   mov    %eax,(%edi)

        ## Indexing off %esp instead of %ebp does cost an extra byte
        ## tho.

        ## Using a register like %ebx instead of a memory location for
        ## a global variable like the allocation pointer costs an
        ## extra byte of initialization, because the initialization
        ## has to be done with a MOV instruction.  Reserving %ebx in
        ## particular to be call-preserved also costs an extra
        ## push/pop pair around every system call, which is currently
        ## 4 bytes.

        ## So, for the time being, I’ve removed %ebx from the set of
        ## call-preserved registers, leaving only %ebp, %esi, %edi,
        ## and of course %esp and %eip.  Somewhat to my surprise, this
        ## initially made the code a byte *larger*, plus 4 bytes of
        ## data; but I quickly recovered the difference by using my
        ## shiny new temporary register.

        ## All three of these remaining registers have global usages:
        ## %esi is used during parsing as the parsing input pointer,
        ## %ebp is used as a base pointer to the global variables, and
        ## %edi is used as the text output pointer (so you can output
        ## a bytes with three bytes: `mov $'(, %al; stosb`.)

        ## Here’s how we’ll define procedures:
        .macro proc name
        .text 1                 # use subsection 1 for library code
\name:
        .endm

        ## Global variables are in the data segment, but in order to
        ## use smaller instructions, we load a pointer to the data
        ## segment into %ebp at startup and then never change it.  So
        ## far I’m not using this everywhere.
        .data
globals:
        .macro my name, initval
        .pushsection .data
\name:  .long \initval
        .popsection
        .endm

        ## Let’s define a macro for things to do at startup.
        .macro init
        .text 0
        .endm

init
        .globl _start
_start: mov $globals, %ebp

        ## We can use this mechanism to reduce the byte weight of
        ## calls to frequently called functions.  The i386 lets you
        ## index into a function pointer table in an indirect-call
        ## instruction: call *4(%ebp), and that’s only 3 bytes, while
        ## a direct call would be 5 bytes, even though it’s
        ## PC-relative.  So with 3 calls, we can reduce 15 bytes of
        ## direct call instructions to 9 bytes of indirect call
        ## instructions and 4 bytes of address data, thus shaving 2
        ## bytes.
        .irp routine, cons, skip_whitespace, read_factor, subst, ev, match
        my \routine\()_address, \routine
        .endr

        ## By using a conditional macro for our calls, we can switch
        ## calls to a given routine between direct and indirect just
        ## by editing the list above:
        .macro do name
        .ifdef \name\()_address
        call *(\name\()_address-globals)(%ebp)
        .else
        call \name
        .endif
        .endm

        ## This interpreter is largely concerned with manipulating
        ## list structure.  Computers nowadays have large memories, so
        ## for any program that runs for a short time, perhaps under a
        ## second, we can get by without a garbage collector.  The
        ## fundamental procedure for constructing list structure is
        ## cons, which creates a pair.  It’s wrapped in a macro here
        ## to facilitate putting it physically after a later procedure
        ## that falls through into it.
        my allocation_pointer, arena
        .macro cons_here
proc cons
        ## This is 11 bytes instead of 21 bytes thanks in part to
        ## replacing two giant 6-byte memory access instructions with
        ## 3-byte things that index off %ebp.
        push %edi
        mov allocation_pointer-globals(%ebp), %edi
        stosl                   # arg 1, the car, is already in %eax
        xchg %eax, %ecx         # arg 2, the cdr, is in %ecx
        stosl
        xchg %edi, allocation_pointer-globals(%ebp)
        xchg %edi, %eax         # return value (old allocation pointer) in %eax
        pop %edi
        ret
        .endm

        ## We’re going to use pointer alignment to distinguish pair
        ## pointers from other kinds of pointers, including the empty
        ## list (nil); specifically, the low 2 bits of a pair pointer
        ## should be 0.  For this, we define a couple of macros for
        ## jumping if a register does or does not point to a pair.  To
        ## avoid wasting bytes, the \reg here should be a low-byte
        ## register: %al, %bl, %cl, or %dl.  %al in particular makes
        ## the `test` instruction 2 bytes instead of 3.
        .macro jpair reg, dest
        test $3, \reg           # will set ZF if it's a pair
        jz \dest
        .endm
        .macro jnpair reg, dest
        test $3, \reg
        jnz \dest
        .endm

        ## Extracting the fields of a pair:
        .macro car src, dest=none
        .ifeqs "\dest", "none"
        mov (\src), \src        # this is only 2 bytes
        .else
        mov (\src), \dest       # 2 bytes
        .endif
        .endm

        .macro cdr src, dest=none
        .ifeqs "\dest", "none"
        mov 4(\src), \src       # 3 bytes
        .else
        mov 4(\src), \dest      # 3 bytes
        .endif
        .endm

        ## Finally, we need some representation for the empty list,
        ## which needs to test as not being a pair.  This is a little
        ## tricky; the chosen value (1) tests as a constant, but
        ## attempting to fetch its print name will crash.
        .macro setnil reg
        xor \reg, \reg
        inc \reg
        .endm

        ## For such a simple allocator to work, we need a large arena;
        ## and the allocation pointer needs to be aligned in it.  We
        ## do this by aligning the arena to a 4-byte boundary and
        ## then incrementing the allocator pointer by multiples of 4.
        .bss 1
        .balign 4
arena:  .fill 512*1024*1024

        ## The other kinds of elements in our list structure are
        ## constants, such as uppercase symbols and numbers, which are
        ## represented by words ending in ...01, and variables, which
        ## are represented internally by words ending in ...10, and
        ## externally as lowercase identifiers.  So we have
        ## conditionals for these types corresponding to jpair and
        ## jnpair to test these tag fields:

        .macro jvar reg, dest
        test $2, \reg           # will clear ZF if it’s a var
        jnz \dest
        .endm
        .macro jnvar reg, dest
        test $2, \reg
        jz \dest
        .endm

        ## XXX these aren’t actually used:
        .macro jconst reg, dest
        test $1, \reg           # will clear ZF if it’s a const
        jnz \dest
        .endm
        .macro jnconst reg, dest
        test $1, \reg
        jz \dest
        .endm


        ## So, let’s define what it means to substitute some variables
        ## into a template:
        ## (define (subst t env)
        ##   (if (var? t) (cdr (assq t env))
        ##       (if (pair? t) (cons (subst (car t) env) (subst (cdr t) env))
        ##           t)))

        ## This is wrapped in a macro in order to enable us to
        ## physically put it further down, where `ap` can fall through
        ## into it.

        .macro subst_here
proc subst
        jnvar %al, 1f           # if t is not a var, jump ahead; otherwise
        do assq                 # look it up with assq (inheriting args), then
        cdr %eax                # we take its cdr, then
        ret                     # return it
1:      jpair %al, 2f           # if t is not a pair, we just return it
        ret                     # (it’s already in %eax)
2:      push %eax               # we must preserve argument t across a call
        push %ecx               # and env too.
        cdr %eax                # get (cdr t) for that recursive call,
        do subst                # which inherits env, but might clobber args;
        xchg %eax, %edx         # socking away its return value in %edx,
        pop %ecx                # restoring env for the second recursive call,
        pop %eax                # and also t, before
        push %edx               # saving the first subst return value on the stack;
        car %eax                # what we want to subst now is (car t)
        do subst                # so now our substed car is in %eax,
        pop %ecx                # and our substed cdr in %ecx, so we can
        jmp cons                # tail-call cons and return the result


        ## `assq` is our function for doing a variable lookup in an
        ## environment.  To avoid an extra unconditional jump, I’ve
        ## relocated the tail end of the loop to before the loop entry
        ## point, which has the bizarre effect of putting it before
        ## the *procedure* entry point.  It happens to set ZF when it
        ## succeeds and clear ZF when it fails, but `subst` ignores
        ## that at the moment.  It might make things simpler if it
        ## returned its key argument when it fails, like `walk` from
        ## μKanren?

2:      cdr %ecx                # go to the next item before falling into assq
proc assq                       # look up an item %eax in a dictionary %ecx
1:      jnpair %cl, 1f          # nil or another atom terminates the dict
        car %ecx, %edx          # get the item
        cmp %eax, 0(%edx)       # is our dictionary key this item?  CISC 4ever!1
        jne 2b                  # if not, restart the loop, or
        mov %edx, %ecx          # on success we return the item, or on failure
1:      xchg %ecx, %eax         # return the non-pair we were examining
        ret
        ## Possibly it would be better to inline `assq` as a macro
        ## inside `subst`, since that’s the only thing that uses it so
        ## far.
        .endm                   # subst_here


        ## In a sense the inverse of `subst` is `match`.  If #(vt) is a var vt,
        ## `(subst '(You #(vt) my #(np)) '((#(np) . wombat) (#(vt) . rot)))`
        ## evaluates to `(You rot my wombat)`, as you'd expect if
        ## you're some kind of psycho stalker, while
        ## `(match '(You rot my wombat) '(You #(vt) my #(np)) '())`
        ## evaluates to `((#(np) . wombat) (#(vt) . rot))`.

        ## In Scheme:
        ## (define (match t pat env)
        ##   (if (var? pat) (cons (cons pat t) env)  ; vars match anything
        ##       (if (pair? pat)  ; pairs match if cars match and cdrs match
        ##           (and (pair? t)  ; a pair pattern can't match an atom
        ##               (let ((a (match (car t) (car pat) env)))  ; match car?
        ##                 (and a (match (cdr t) (cdr pat) a))))   ; then, cdr?
        ##           (and (equal? pat t) env))))  ; consts match only themselves

        ## In addition to returning an environment result in %eax,
        ## `match` also needs to indicate success or failure, which it
        ## does with ZF: ZF set indicates match (“equality”), ZF clear
        ## indicates match failure.  Switching from CF to ZF reduced
        ## the weight of this subroutine from 85 bytes to 76 bytes,
        ## and with further work it’s down to 55.

        ## This has a bug; it treats () the empty list as a var. So
        ## (Gallygoogle ()) matches the same patterns (Gallygoogle x)
        ## would.

proc match
        ## Case for pattern being an unadorned var:
        jnvar %cl, 2f           # If the pattern is a var,
        xchg %eax, %ecx         # we want to (cons pat t), not (cons t pat)
        push %edx               # save env
        do cons
        pop %ecx                # now cons that pair onto the original env
        do cons
        xor %ecx, %ecx          # set ZF to indicate success
        ret

        ## Case for matching a non-pair against a pair pattern:
2:      push %ecx               # for recursion, we must save pattern and
        push %eax               # t, the term being matched.
        jnpair %cl, 2f          # ensure pattern is a pair;
        jnpair %al, 1f          # if term is not a pair, fail (clearing ZF);

        ## To match two pairs:
        car %eax                # take car of both the term
        car %ecx                # and of the pattern
        do match                # and allow env to inherit in a recursive call;
        jne 1f                  # if that failed we bail out;
                                # otherwise,
        xchg %eax, %edx         # put the resulting env in the third param
        pop %eax                # and get original term
        cdr %eax                # for second recursion with (cdr t), and likewise
        pop %ecx                # pat for
        cdr %ecx                # (cdr pat).
        jmp match               # tail-recursing; it’s my result, right (ZF) or wrong (!ZF)

        ## To match a constant pattern:
2:      cmp %ecx, %eax          # Only succeed on exact equality,
        mov %edx, %eax          # returning the supplied env

        ## Shared epilogue (XXX maybe unshare it?)
1:      pop %ecx                # discard 2 saved arguments
        pop %ecx
        ret


        ## ev evaluates a term by first evaluating all its children
        ## with evlis (which is just `(map ev t)`), then invoking
        ## ap(ply) on the result.
        ## (define (ev t)
        ##   (if (pair? t) (ap (evlis t) rules) t))
        ## (define (evlis t)
        ##   (if (pair? t) (cons (ev (car t)) (evlis (cdr t))) t))
proc evlis
        jpair %al, 1f
        ret
1:      push %eax               # save original t
        cdr %eax
        do evlis
        pop %ecx                # restore original t
        push %eax               # save return value
        xchg %ecx, %eax         # 1 byte — shorter than mov %ecx, %eax
        car %eax
        do ev
        pop %ecx                # pass evlis return value as cdr arg to cons
        # FALL THROUGH into cons (tail call)
        cons_here

        ## I’m thinking I’ll provide primitive procedures for
        ## arithmetic and file I/O by way of terms whose head is the
        ## integer “0”.  For example: integer subtraction.  Here we
        ## have the term in %eax.  This untested strawman evprim
        ## weighs 25 bytes, plus 7 bytes for the test and branch in
        ## ev.
proc evprim
        cdr %eax
        car %eax, %ebx
        cdr %eax
        cmp $5, %ebx  # (0 0 x y) returns x - y assuming both are ints
        jnz 1f
        car %eax, %ebx
        cdr %eax
        car %eax
        sub %ecx, %eax      # XXX is this backwards?
        or $5, %al          # low-order bits got zeroed by subtraction
1:      ret

        my rules, -1            # global set of rules, initially nil
proc ev
        jpair %al, 1f
        ret                     # atoms always evaluate to themselves
1:      do evlis
        car %eax, %ecx                # check for primitive invocation
        cmp $5, %ecx                  # is the car of the list (tagged) 0?
        jz evprim
        mov rules-globals(%ebp), %ecx # initial rules argument to ap: the global
        # FALL THROUGH to ap


        ## (define (ap t rules)
        ##   (if (not (pair? rules)) t   ; no rewrite rules left? don't rewrite
        ##       (let ((m (match t (caar rules) '()))) ; initially empty env
        ##         (if m (ev (subst (cdar rules) m)) ; matched? subst & eval
        ##             (ap t (cdr rules))))))         ; otherwise, try others
proc ap
        jpair %cl, 1f
        ret                     # return input t

1:      car %ecx, %edx          # get first rule
        push %eax               # save input t
        push %ecx               # save input rules
        car %edx, %ecx          # get pattern part of rule
        setnil %edx
        do match                # see if this rule matches inherited t in %eax
        je 1f                   # if that succeeded, go to the success case; or

        pop %ecx
        pop %eax

        cdr %ecx                # move on to next rule and tail-recurse
        jmp ap

        ## Now we have found a match, with the env in %eax; now we
        ## must invoke subst with the template, then return the
        ## instantiated template.
1:      mov %eax, %ecx          # template is subst’s second argument
        pop %eax                # load saved rules
        car %eax
        cdr %eax
        pop %edx                # discard saved input t
        do subst
        jmp ev

        subst_here                      # XXX no longer necessary to be here

        ## Here are some macros from httpdito:
        .equiv __NR_exit, 1     # linux/arch/x86/include/asm/unistd_32.h:9
        .equiv __NR_read, 3
        .equiv __NR_write, 4

        ## System calls with different numbers of arguments.
        ## `be x, y` is a macro that does `mov x, y` or equivalent.
        .macro sys3 call_no, a, b, c
        be \c, %edx
        sys2 \call_no, \a, \b
        .endm

        .macro sys2 call_no, a, b
        be \b, %ecx
        sys1 \call_no, \a
        .endm

        .macro sys1 call_no, a
        be \a, %ebx
        sys0 \call_no
        .endm

        .macro sys0 call_no
        be \call_no, %eax
        int $0x80
        .endm

        ## Set dest = src.  Usually just `mov src, dest`, but sometimes
        ## there's a shorter way.
        .macro be src, dest
        .ifnc \src,\dest
        .ifc \src,$0
        xor \dest,\dest
        .else
        .ifc \src,$1
        xor \dest,\dest
        inc \dest
        .else
        .ifc \src,$2
        xor \dest,\dest
        inc \dest
        inc \dest
        .else
        mov \src, \dest
        .endif
        .endif
        .endif
        .endif
        .endm

        ## To read input, we need an input buffer; to intern atoms, we
        ## need someplace to put the atom base+length pairs.
        .bss
input_buffer:
        .fill 65536
        .balign 8   # atoms need to be 8-byte aligned to free tag bits
atoms:  .fill 8192
        my inptr, input_buffer
        ## Output is handled by setting %edi to point into this output
        ## buffer, then using stosb to add stuff to it.
        .bss
outbuf: .fill 131072

init
        mov $outbuf, %edi

        .data
prompt: .ascii "↪ "
prompt_end:
init
repl:   mov $prompt, %eax
        mov $(prompt_end - prompt), %ecx
        do emit
        do flush
        sys3 $__NR_read, $0, inptr, $255
        test %eax, %eax         # EOF on input?
        jz quit
        ## XXX missing loops for \n; could be multiple lines or partial lines
        mov inptr-globals(%ebp), %esi # copy old inptr to %esi for parsing
        add %esi, %eax  # NUL-termination unnecessary due to zero fill
        mov %eax, inptr-globals(%ebp)
        do handle_line
        jmp repl
quit:   sys1 $__NR_exit, $0

        ## XXX this needs a lot of attention for reducing code space
proc print
        cmp $1, %eax    # treat nil like pairs (cmp is only 3 bytes!)
        je 5f
        jnpair %al, 1f          # non-nil atoms treated otherwise
5:      push %eax               # save S-expression to print
4:      mov $'(, %al
        stosb
        pop %eax
        ## loop over list items:
2:      jnpair %al, 3f          # XXX handle improper lists?
6:      push %eax
        car %eax
        do print
        pop %eax
        cdr %eax
        jnpair %al, 3f
        push %eax
        mov $32, %al
        stosb
        pop %eax
        jmp 6b                  # XXX too many jumps?
3:      mov $'), %al
        stosb
        ret
1:      and $~3, %eax        # convert var/constant → base/len pointer
        cdr %eax, %ecx
        car %eax
        ## FALL THROUGH into a tail call to `emit`

proc emit                       # output a string to output buffer
        push %esi
        mov %eax, %esi          # string base is arg 1, length is arg 2 (%ecx)
        rep movsb
        pop %esi
        ret

proc flush                      # Send output buffer to actual stdout
        mov $outbuf, %ecx       # base address of bytes to output
        push %ecx
        mov %edi, %edx
        sub %ecx, %edx          # number of bytes to output
        sys1 $__NR_write, $1
        pop %edi                # reset output pointer
        ret

        ## Our grammar looks something like:
        ## prog ::= _ (factor (_ "\n" | _ factor _"\n"))*
        ## factor ::= constant | var | "(" (_ atom)* _ ")"
        ## _ ::= " "*
        ## constant ::= [*-^][*-~]*
        ## var ::= [_a-~][*-~]*
        ##
        ## Constants and vars chew up as many characters as they can.
        ##
        ## A line with two S-expressions (“factors”) defines a rule; a
        ## line with just one offers an expression to evaluate
        ## according to the rules so far.

        ## On inputting a rule, it is added
        ## to the front of the rules list (thus taking precedence over
        ## older rules).

        ## Here’s a crude parser.  Input pointer in %esi points
        ## into NUL-terminated input string.
proc handle_line
        cld        # XXX not really necessary since DF is always clear
        do read_factor
        jz 1f                   # if blank line, ignore
        ret
1:      push %eax
        do skip_whitespace
        lodsb    # lodsb;dec: 2 bytes, cmp $'\n, %al: 2; cmp $':, (%esi): 3
        dec %esi # so this approach saves bytes only because of second cmp
        cmp $'\n, %al # if there’s only one expression on the line, not a rule
        jnz 1f
        pop %eax
        do ev
        do print
        mov $'\n, %al
        stosb
        ret
1:      do read_factor # read replacement template for rule being defined
        pop %ecx                # pop pattern
        jnz parse_error
        ## XXX ignoring the possibility of more than two things on the line
        xchg %ecx, %eax
        do cons
        ## FALL THROUGH into tail call to add_rule

proc add_rule
        mov rules-globals(%ebp), %ecx # cons onto the existing set of rules
        do cons
        mov %eax, rules-globals(%ebp)
        ## debug print out rules:
        ## do print
        ## mov $'\n, %al
        ## stosb
        ## do flush
        ret

proc parse_error
        mov $'!, %al
        stosb
        mov $'\n, %al
        stosb
        ret

proc read_factor
        do skip_whitespace
        lodsb
        dec %esi                # peeking
        cmp $'(, %al            # Is there a nested list?
        jne 1f
        lodsb
        do read_term
        push %eax
        do skip_whitespace
        lodsb
        cmp $'), %al            # indicate success
        pop %eax
        ret
1:      cmp $'*, %al            # [*-^] starts a constant
        ## <https://stackoverflow.com/a/29577037> explains that with
        ## cmp $2, %eax, jg jumps when %eax > 2, though this is
        ## confusing as
        ## <https://en.wikibooks.org/wiki/X86_Assembly/Control_Flow>
        ## explains; so this comparison has the correct sense:
        jb 3f
        cmp $'^, %al
        ja 2f
        jmp read_constant
2:      cmp $'_, %al            # _ starts a variable
        je 2f
        cmp $'a , %al           # [a-~] also starts a variable
        jb 3f
        cmp $'~, %al
        ja 3f
2:      jmp read_var
3:      cmp $'_, %al # guaranteed to fail and clear ZF, indicating failure.
        ret

        ## Advance input pointer %esi into NUL-terminated input string
        ## to first non-whitespace character.
proc skip_whitespace
        lodsb
        cmp $32, %al
        je skip_whitespace
        dec %esi
        ret

        ## Always succeeds (possibly returning nil), doesn’t set ZF.
proc read_term
        do read_factor
        jnz 1f                  # if it failed, skip ahead
        push %eax               # save returned term
        do read_term            # recursive call for tail of term
        push %eax
        do skip_whitespace
        pop %ecx
        pop %eax
        do cons                 # XXX tail call
        ret
1:      setnil %eax             # return nil if no factor found
        ret

        ## Always succeeds, sets ZF to indicate success.
proc read_constant
        do read_atom
        ## xor $3, %al is also 2 bytes, same as or $1, %al
        ## So XXX maybe one of these two should fall through into
        ## intern and the other should xor the output of intern with 3
        or $1, %al
        cmp %eax, %eax          # set ZF
        ret

        ## Always succeeds, sets ZF to indicate success.
proc read_var
        do read_atom
        or $2, %al
        cmp %eax, %eax
        ret

        ## Octal to tagged integer.  Digit count in %ecx, input starts
        ## at %esi.  19 bytes.  Not used yet.
proc o2ti
        xor %eax, %eax
        xor %ebx, %ebx          # accumulate result in %ebx
1:      lodsb
        sub $'0, %al            # convert digit from ASCII
        add %eax, %ebx
        shl $3, %ebx     # by shifting after the add instead of before,
        loop 1b
        xchg %eax, %ebx
        add $5, %eax            # we leave space for this type tag
        ret

        ## Decimal to tagged integer.  Digit count in %ecx, input
        ## starts at %esi.  22 bytes.  Not used yet.  If the
        ## difference is only like 6 bytes maybe I’ll just use
        ## decimal.
proc d2ti
        xor %eax, %eax
        xor %ebx, %ebx          # accumulate result in %ebx
1:      lodsb
        sub $'0, %al            # convert digit from ASCII
        imul $10, %ebx
        add %eax, %ebx
        loop 1b
        xchg %eax, %ebx
        shl $3, %eax
        add $5, %eax
        ret

        ## Tagged integer to octal, taking integer in %eax.  Outputs
        ## to buffer at %edi.  25 bytes.  Not used yet.
proc ti2o
        xchg %eax, %ebx
        xor %eax, %eax          # clear high bytes of %eax for the loop
1:      shr $3, %ebx            # shift first to remove type tag
        mov %bl, %al            # still only 2 bytes!
        and $7, %al             # 2 bytes, shorter than `and $7, %eax`
        add $'0, %al            # convert to ASCII
        test %ebx, %ebx         # don’t recurse if no digits remain
        jz 1f
        push %eax               # buffer up digit for later emission
        call 1b
        pop %eax
1:      stosb
        ret

        ## I’m thinking about adding character string literals, in a
        ## form like this maybe.  This function would be called after
        ## the open-quote.  51 bytes.
proc read_string
        xor %eax, %eax
        lodsb
        cmp $'", %al
        jne 1f
2:      xor %eax, %eax          # tagged integer 0 as list terminator
        mov $5, %al # this is 4 bytes rather than the 5 of mov $5, %eax
        ret
1:      cmp $'\n, %al
        je 2b                   # just treat this as end of string
        cmp $'\\, %al           # treat \" as embedded "
        jne 1f
        lodsb
        cmp $'\n, %al
        je 2b
1:      push %eax
        do read_string          # read rest of string
        pop %ecx
        xchg %eax, %ecx         # get saved character back in %eax
        shl $3, %eax
        or $5, %al              # add integer tag
        do cons
        xchg %eax, %ecx
        xor %eax, %eax
        mov $13, %al            # tagged integer 1
        jmp cons # XXX probably place this closer to cons so this jump is short

        ## Always succeeds.
proc read_atom
        mov %esi, %edx          # save address of start byte
1:      lodsb
        cmp $'*, %al
        jb 1f
        cmp $'~, %al
        jbe 1b
1:      dec %esi                # put back last character read
        mov %esi, %ecx          # save end address, then compute length:
        sub %edx, %ecx          # $ecx -= $edx, due to confusing AT&T syntax
        xchg %eax, %edx
        ## FALL THROUGH into intern

        ## (intern base-addr len) checks to see if a string is already
        ## in the atom table, returning it if so, or inserting it if
        ## not; either way it returns the (4-byte-aligned) address.
        ## Can’t fail.  Can’t use assq because it’s doing a string
        ## compare.
proc intern
        push %esi
        push %edi
        mov $atoms-8, %ebx
        ## At the top of the following loop, %ebx points into (or just
        ## before) the atoms table, %eax points to the string we’re
        ## trying to intern, and %ecx has its length.
1:      add $8, %ebx         # Advance to next table entry.
        mov (%ebx), %edi     # Load string pointer from table.
        test %edi, %edi      # null string pointer? indicates end of table
                             # test %edi, %edi is one byte smaller than cmp $0.
        jz 2f                # reached end of table without finding it
        cmp %ecx, 4(%ebx)    # check to see if the lengths match
        jne 1b
        push %ecx            # repe will clobber %ecx
        mov %eax, %esi       # put pointer to needle string into %esi
        repe cmpsb
        pop %ecx
        jne 1b               # go on to next entry unless we found it
1:      mov %ebx, %eax       # address of found entry (table pointer)
        pop %edi
        pop %esi
        ret
2:                       # not found, must insert
        mov %eax, (%ebx) # non-null pointer here says this is no longer the end
        mov %ecx, 4(%ebx)
        jmp 1b               # now that we’ve inserted it, it’s “found”
