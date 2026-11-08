# Look-ahead and register spilling

Jay requested these after the first native self-hosting proof. Compiler logic
remains Gleam, with owned x86-64 code generation. No external backend or runtime.

## First bounded increment

The old binary-expression path evaluates left into RAX, pushes it, evaluates
right into RAX, then pops left into RCX. The operator consumes RCX=left, RAX=right.

Look ahead at the typed RHS. Integer/Bool/Nil literals and local reads have no
calls, effects, traps or scratch-register clobbers. For these leaves only:

* A leaf left value is materialized directly in RCX, then right in RAX.
* A compound left expression runs normally, then its completed RAX value moves to
  RCX before evaluating the leaf right operand.
* A non-leaf RHS keeps the push/pop spill. Calls, helpers, nested expressions,
  allocations, comparisons and effectful expressions are not presumed safe.

No operand is reordered. Short-circuit operators keep their existing branch path.
Overflow and division/remainder behavior keep their existing checked operator
instructions. Strings use the same helper ABI after their operands are prepared.
Structural equality has its separate existing lowering and is not changed here.

This is local register retention with a conservative spill decision, not a
whole-function allocator, liveness analysis or a claim that all frame slots are
spills. Existing locals/parameters still occupy their original slots.

## Register and boundary contract

R14/R15 are reserved arena end/cursor. RBP/RSP define the owned frame/stack ABI.
The accumulator is RAX; RCX is the left-operand scratch value at operator entry.
No retained RCX value survives an unknown call in this increment. Internal calls
do not automatically follow SysV preserved-register rules. Linux syscall clobbers
RCX/R11; helper bodies must be inspected before extending a live register range.

Future register allocation needs an explicit owned instruction representation,
use/def and clobber sets, control-flow liveness, interference or live intervals,
reserved-register exclusions and spill-slot reuse. Loop joins, closures/captures,
tail parameter replacement, helpers and syscalls all need tests. No speculative
whole-function allocation should be enabled based on this leaf optimization.

## Qualification and measurements

Use exact fixed target source to compare old/new emitters; report current-source
image growth separately. Actual objdump windows must show absent unnecessary
push/pop and retained necessary spills across calls. Static counts do not prove
execution frequency or speed; frame loads include local/parameter traffic.

Regression coverage includes noncommutative arithmetic, wide literals, overflow,
division by zero, short circuiting, effect order, nested calls and string helpers.
Then rerun the full independent upstream corpus, native IO and two exact native
self-rebuilds. Keep the first self-hosting evidence under its original filenames.

Development invocation for separately named receipts:

```sh
GIG_VERIFY_PREFIX=leaf-register python3 verify.py
```

Without a prefix, the verifier writes current-* development receipts.
The first milestone remains recorded in evidence/self-hosting-*. New results are
written to evidence/leaf-register-* and owned-component equivalents.

## Fixed-source result

The source graph is held at e099363 (the qualified first self-hosting compiler).
Only the emitter changes. Across its 381 named functions, the emitted static totals
change from 71,572 to 71,121 instructions, 7,423 to 7,163 pushes, and 3,973 to 3,713
pops. Thus 260 push/pop pairs and 451 instructions disappear. The complete fixed-
source image drops from 592,047 to 591,713 bytes. Frame-memory instructions remain
13,146; this increment does not perform frame-slot allocation or reuse.

[evidence/leaf-register-comparison.json](evidence/leaf-register-comparison.json)
records exact source/emitter/image identities and static deltas. This is a
controlled emitter comparison, not the size of the newer compiler source after
adding the optimization's own implementation, and not a runtime speed benchmark.

## Independent oracle finding

The first broader run exposed an older lexical mismatch in the new nested-effect
fixture: `mark(3)-1` is two expressions upstream (call, then signed literal), while
`mark(3) - 1` is subtraction. The prior native compiler also produced the wrong
result for the unspaced call case; register staging did not cause it.

The lexer now tracks the previous token end across whitespace/comments. A minus
adjacent to digits remains subtraction only when adjacent to a preceding word or
number; otherwise it begins a signed numeric token. Calls/closing delimiters,
whitespace/newlines, comments, underscores, minus-negative and argument boundaries
have independent upstream/runtime fixtures. The original failing source and both
observations remain in evidence/leaf-register-initial-upstream-failure.json.
