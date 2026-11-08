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
Legacy lowering uses RAX for the accumulator/right operand and RCX for the left.
Typed regions below use explicit instruction operands instead.
No retained RCX value survives an unknown call in this increment. Internal calls
do not automatically follow SysV preserved-register rules. Linux syscall clobbers
RCX/R11; helper bodies must be inspected before extending a live register range.

Whole-function register allocation still needs an extended owned instruction representation,
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

## Sibling-arm stack slots

Single- and multi-subject case arms are mutually exclusive. Save the slot count
at arm entry (after common subjects), compile the pattern/guard/body, then compile
its siblings from that same base. Return the maximum slot count across arms to
reserve the complete function frame. Outer locals and subject slots remain below
the shared base; positive parameter offsets are unchanged. Joins reserve the
maximum rather than summing all sibling footprints.

Only sibling-arm locals overlap. Locals are not reused after an entire case or
within a single arm; pattern alternatives retain their existing conservative
allocation. Closure captures are copied values in owned heap descriptors, never
pointers to these local slots. Closure helper frames retain their separate scope.
Guard failure and next-arm jumps may overwrite the previous arm's dead locals.

Regression coverage includes outer values used after the join, escaped captures,
failed guards, nested cases, multi-arm canonical bindings, returned heap values
and direct tail loops. Actual instruction tests check a representative single-case
frame is 32 bytes and a multi-case frame is 48 bytes, reserving the largest arm.
Fresh full upstream/native IO/self-rebuild qualification remains mandatory.
This is bounded stack-slot reuse, not whole-function liveness/register allocation.

Qualified: 687 regression checks, 341 fresh upstream comparisons and the complete
341-case rebuilt-native corpus. Two successive native self-rebuilds match their
seed. Fixed-source frame totals drop 36,800 to 26,112 bytes across 384 named
functions (95 shrink). This is not a dynamic stack measurement. The separate
64 KiB non-tail recursion comparison succeeds with a 32-byte frame where the
historical 208-byte frame fails; both exact image/source identities are retained.
Receipts: evidence/branch-slots-qualification.json,
evidence/branch-slots-frame-comparison.json, evidence/branch-slots-small-stack.json.

## Typed integer regions and liveness

The next increment adds native/registers.gleam, an owned typed instruction plan
for checked Int addition/subtraction/multiplication/negation. Constants, local
reads and single-expression grouping blocks are admitted. Calls, effects,
bindings, case branches, division and other operations retain the old lowering.
Only an eligible region is replaced; it returns its value in RAX at the boundary.

The pool is RAX/RCX/RDX. Recursively allocate the left subtree first, then the right
from the remaining registers. With one available register, push the completed
left value, compute right, pop left into reserved RDI, execute the operation and
copy its result back. RDI is never allocated as a persistent value. Nested spills
may reuse RDI only after each inner result is copied back. R14/R15, RBP/RSP and
unknown caller-preserved assumptions are excluded from allocation.

Instruction variants describe constants, local reads, copies, push/pop, arithmetic,
negation and overflow guards. Explicit uses/definitions include condition Flags.
Backward straight-line liveness computes uses union (live-out minus definitions).
The actual emission pipeline uses it to remove dead materializations and copies.
Arithmetic, overflow guards and push/pop are always retained: dead result values
do not authorize removing traps, changing trap order or unbalancing the stack.
Every arithmetic instruction is immediately followed by its overflow guard before
later operand work. No effectful operation can enter the typed region.

This is real expression-region allocation and liveness, not whole-function CFG
allocation. General joins, calls, callee conventions, live intervals and lifetime
reuse across those boundaries remain explicit future work. Raw instruction bytes
outside typed regions remain barriers until their effects are represented.

Regression coverage includes actual three-register arithmetic without spills,
nested spill recovery with noncommutative operations, flags liveness, dead copies,
overflow before multiplication by zero, effect/call/control-flow fallback,
wide literals and exact native rebuild/corpus qualification.

The seeded independent stress oracle generates 100 expressions in one program,
keeps every intermediate within exact +/- (2^53-1), and compares native output,
upstream output and BigInt expectations. 68 regions spill, with maximum fixed-order
operand pressure seven. The native executable also matches bootstrap bytes.
This complements separately tested overflow behavior; it is not a speed benchmark.
The fixed compiler-source comparison removes 15 push/pop pairs, 54 named-function
instructions and 116 image bytes. That excludes the added planner implementation.
Receipts: evidence/integer-regions-seeded-oracle.json and
evidence/integer-regions-comparison.json.

Qualified region increment: 702 regression tests, 351 fresh upstream comparisons,
351 rebuilt-native corpus cases and two exact native self-rebuilds. The seeded
oracle is separate. The IO receipt path now derives from its actual disassembly
output instead of a historical hardcoded filename; all 59 IO tests were rerun
with identical compiler source/image, and the initial receipt is retained.

Repeat the separate seeded oracle after building the generated JS bootstrap and
a native compiler (development tools only):

```sh
node tools/verify_register_regions.mjs out/gleam-native out/register-region-oracle.json
```

## Named calls and caller-save allocation

Named Int-returning calls whose arguments are supported integer trees now enter
regions. Their stack ABI is unchanged: evaluate arguments in source order and
push each result; call fn:NAME; remove exactly argument_count words. Dynamic
function descriptors and non-integer arguments are outside this increment.

Every allocatable register RAX/RCX/RDX, reserved recovery RDI and Flags is killed
by a named callee. The definitions/kill set is consumed by backward liveness;
only RAX contains a valid return value. Other killed values must not be used until
restored. R14/R15 are reserved allocator state, not caller values to roll back.

The occupied prefix of the register pool contains pending ancestor operands.
Push it BEFORE argument evaluation, then evaluate each argument using a fresh
pool, since previous arguments are already on the stack. Nested calls cannot
silently overwrite an outer live value. After the call, copy its RAX return into
the available target register before popping saved registers in reverse order.
The target is not among the saved prefix. RDI cannot hold a persistent live value
across a call. Arithmetic guards remain immediate; call/stack effects are never
removed by dead-move elimination. Argument words are consumed by call cleanup,
while caller saves and pressure spills have explicit matching pops.

Qualification: 715 tests, 361 independent upstream corpus comparisons and native
cases, and two exact native self-rebuilds. A separate seeded 100-expression call
program checks 286 calls and 386 effect observations against upstream and an
independent BigInt/effect model. The original pure stress program still has its
previous source/image hashes. The compiler-source fixed image/instruction counts
are unchanged; this does not claim faster execution. Caller result coalescing,
indirect calls, non-integer arguments and general control-flow joins remain open.

```sh
node tools/verify_register_regions.mjs out/gleam-native out/call-region-oracle.json --calls
```

Current receipts: evidence/named-calls-qualification.json,
evidence/named-calls-seeded-effects.json, evidence/named-calls-seeded-pure.json,
evidence/named-calls-comparison.json.

## Scalar branches and control-flow joins

The typed plan now includes comparisons, Mark, Jump and JumpZero. It admits scalar
Boolean expressions, short-circuit AND/OR/NOT, and supported two-arm Boolean or
Int-literal/default cases without bindings/guards. Conditional subjects evaluate
once; only the selected arm executes. Both paths produce RAX, then the join copies
that result to its assigned register before restoring pending outer operands.
Each region has its own assembly-label namespace. RDI spill recovery supports
low-byte SETcc with an explicit REX prefix and zero extension.

Liveness uses the union of successor live-ins, not textual fallthrough across
branches. A backwards fixed point supports backedges; duplicate/missing labels
are errors. Labels, jumps, calls, arithmetic traps and stack effects are retained.
Dead moves are removed only against the actual live-out set, repeating if needed
for transitive dead copies. Straight-line regions retain the earlier qualified
linear pass instead of paying for graph rows and a fixed point.

General pattern bindings, guards, multi-subject/data-valued matches and unmodeled
call arguments remain legacy barriers. This is not full whole-function allocation
for all language constructs. The benchmark report states that scope explicitly.
Two initial aggregate verifier timeouts are retained: the first exposed unnecessary
CFG work on straight-line regions; the second showed the multi-stage job required
an aggregate allowance above 60 seconds. Only the aggregate limit is now 180;
the individual native process limits remain unchanged.

The branch oracle generates 100 expressions and compares selected-path effects
and values to upstream and an independent model. Its 271 observed effects exclude
untaken branches; static call counts span both paths. Pure/call stress inputs are
also rerun. Generated test programs, corpus cases and benchmark workloads are
reported as separate evidence categories, not inflated into one compilation count.

Final qualification for this pass: 729 tests, 371 independent upstream/corpus
cases, two native self-rebuilds, and all three seeded oracles. The benchmark report
contains two source-input cohorts and shorter/longer runtime trials. Scope remains
explicit: supported scalar joins are implemented; general whole-function and
pattern/data lowering remain future work. No broad speedup is claimed.
