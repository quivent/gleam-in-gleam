# Compiler implementation journal

## Captures and `use` — 2026-11-07

The raw named-function-pointer representation could not carry returned captured
values safely. We replaced first-class values with arena-owned descriptors holding
static code pointers and copied capture words. Direct named calls retain their
existing parameter convention; indirect calls save a descriptor word which closure
helpers use to recover the environment. No stack addresses escape through captures.

Anonymous-parameter inference needed explicit context propagation through bindings,
constructor arguments, function results and case branches. Callback checking waits
for non-lambda argument evidence before checking a lambda; generated argument
evaluation order remains unchanged. `use` lowers to that same callback mechanism.

Verification: 210 checks and 31 fresh upstream comparisons. The closure executable
is 1,021 bytes, while the named-function example changes from 867 to 1,050 bytes
because descriptors now allocate. This is an explicit ABI cost, not evidence of
compiler or program speed. Historical raw-pointer artifacts remain preserved.

## Immutable record updates — 2026-11-07

Initial upstream probes established that updates may change a generic parameter,
that replacement fields evaluate in declaration order rather than source label
order, and that a multi-variant value must be known to have the named constructor.
We therefore save the original once and lower to fresh construction, using retained
fields as constraints on the output parameters. A source-AST free-name traversal
also visits updates so captured record values remain available inside closures.

The larger combined oracle exposed a bootstrap stack limit in assembler emission:
11 of 227 checks initially failed with `Maximum call stack size exceeded` in the
relocation emitter, while 216 passed. The old pass recursively waited for the tail
before producing each chunk. We changed it to a direct tail-recursive accumulator
and added a forward relocation over 12,000 instructions. The next full run passed
228 checks and 39 upstream comparisons, preserving all earlier binary hashes.

Final edge probes found that a zero-field constructor is not a valid update
constructor, and phantom type parameters may change independently of the original.
Both rules are reflected in the checker and differential fixtures. A retained
generic field also supplies parameter context to an anonymous replacement callback.
Final evidence: 230 checks, 42 upstream comparisons, and the 930-byte update example.
See the frozen receipts and ASM.md for actual bytes and addresses.

The compiler remains Node-bootstrapped. These milestones implement correctness in
owned Gleam source without adding third-party packages. Bit arrays, module graphs,
remaining inference/semantics, native compiler IO and memory reclamation still
stand between this seed and an actual stage-1/stage-2 self-hosting demonstration.
No compiler-speed benchmark or finished compiler-size claim follows from these
feature tests. Optimization follows correctness, with emitted ASM kept visible.

## Byte-aligned bit arrays — 2026-11-07

We added owned construction, concatenation, fixed integer encoding/decoding and
final-tail matching in Gleam. Every supported width and endian order is tested
against explicit byte literals, so mutually wrong encoders/decoders cannot hide
behind a round trip. Signed extraction and low-bit truncation are separate rules.
Construction and matching options are validated separately: `signed`, `unsigned`
and `bytes` are pattern-only options upstream.

Initial oracle preparation caught two frontend distinctions: arithmetic segment
expressions need braces, and `<<>>` plus a nonempty-byte pattern is not exhaustive
for the full BitArray type. The latter may contain unaligned bits upstream. We
kept that conservative rule and preserved `bits` versus `bytes` tail coverage;
we did not use our narrower runtime representation to accept invalid source.

A fresh side-effect comparison then failed: we evaluated the expression of a
statically zero-width integer segment, but upstream did not. The exact failing
comparison is retained in evidence/bit-arrays-zero-width-failure.txt. The checker
still validates that source, while native emission omits the runtime evaluation.
The final differential suite now includes that exception explicitly.

Native slices retain a root-owner pointer, alongside their length and data pointer.
This adds a word now so future collection need not guess the owner of an interior
pointer. Current lifetime still comes from the bounded arena, not a hidden GC.
Runtime tests also exhaust the arena through actual repeated concatenation and
verify exit 71 before an oversized copy. Unsigned 64-bit variable extraction keeps
the existing signed-native-Int limit; discards and impossible literal comparisons
avoid falsely interpreting high-bit unsigned bytes as negative values.

Final verification: 293 tests, 64 upstream acceptance/runtime comparisons, zero
third-party dependencies. The 1,825-byte native example has no loader/libraries,
and all eight preceding example hashes are unchanged. Its ASM is retained with
actual length guards, owner copies and REP MOVSB addresses. No speed claim or
self-hosting claim follows: modules, remaining semantics, native IO and collection
remain necessary work.

## Local modules and visibility — 2026-11-07

We added a pure Gleam project pass rather than concatenating files in JavaScript.
The host bridge follows compiler-parsed file requests; import graph traversal,
cycles, visibility, lexical scopes and names are resolved in Gleam. Distinct
internal names prevent private/public helpers and nominal types from colliding
across modules. Shared dependencies link once in deterministic import order.

Qualified calls become ordinary checked calls; qualified constructor/type/pattern
and update references become module-qualified declarations. Upstream probes showed
that local values shadow lowercase module access, while qualified constructors
retain their module namespace. Module aliases can also coexist with global
function names, and a module may be imported twice under different aliases. These
cases are now executable differential fixtures, not assumptions about the grammar.

The first baseline run had 291 of 293 checks passing. Both failures were diagnostics:
missing imports now report a missing source instead of unsupported syntax, and a
discarded lambda name was rejected too early as unknown. We updated the changed
import diagnostic and restored explicit discard checking before name resolution.

The first module oracle also exposed a testing classification error: upstream
allows builtin-type shadowing, which our seed explicitly does not implement.
That rejection must not be called an upstream agreement. The failed reference is
preserved in evidence/modules-builtin-shadow-limit.txt. Its fixture remains a
separate native restriction check, ensuring module name mangling cannot silently
bypass the existing restriction and change the meaning of builtin annotations.

Final evidence is 336 checks and 97 fresh upstream comparisons (64 single-module,
33 project fixtures). A multi-file example links to a 1,060-byte executable with
no loader/shared libraries. Its resolved names and actual relative call targets
are recorded. The previous nine examples remain byte-identical, and a fixture
matches equivalent manually flattened single-module code exactly. No timing claim
follows from this static-linking evidence.

Selective imports, package resolution, remaining language syntax/semantics and
native compiler IO/collection remain open. The compiler still runs through the
explicit Node bootstrap. No installed compiler or unrelated repository was changed.

## Transparent aliases and pure guards — 2026-11-07

Type aliases now resolve in their defining module's scope, including generic and
forward references. Expansion stops at nominal constructors, allowing legal
recursive nominal data while rejecting infinitely expanding alias cycles. Every
alias is validated even when unused. Parameters must be declared, distinct and
used; discard names are rejected for aliases and nominal type parameters.

Privacy required testing rather than assuming that an alias name was a new type.
Upstream permits a private alias of a public type in a public function signature.
A public alias of a private nominal type can be declared unused, but cannot make
that private type legal in a public function interface. Expansion retains the
underlying nominal privacy, while imported alias names retain their own visibility.
A cross-module fixture also verifies that alias bodies bind names in the defining
module, avoiding accidental capture by same-named caller types.

Guards share the existing native expression operators, with explicit source-form
validation. Pattern bindings are available to the condition and body; false
conditions jump to the next arm without leaking those names. Guarded arms are
excluded from coverage proofs, even for literal True. Grouping is accepted;
calls, let bindings and echo are rejected. Some pure construction/structural guard
forms are valid upstream but remain explicitly unsupported in this seed.

Guard free names participate in closure capture analysis. A returned factory
callback captures a threshold used only in its guard and retains it after the
factory returns. Native tests also show short-circuiting avoids an overflowing
operand, and a failed guard recovers the surrounding name bindings correctly.

The existing 336 checks passed unchanged before the new fixtures were added. Final
qualification passes 382 checks and 141 upstream comparisons: 64 single-file plus
77 project fixtures. The new 1,269-byte executable has recorded guard branches and
capture loads. Aliases match underlying tuple machine code byte-for-byte, and all
ten preceding native examples retain their exact hashes. Zero third-party package
dependencies remain. No self-hosting or speed claim follows; remaining strings,
prelude/inference/syntax and native IO/memory management are still necessary.

## Strings and implicit Result — 2026-11-07

We preserved the exposed static String layout rather than changing every earlier
program. Owned dynamic strings add an allocation-size/tag header before that value
pointer, use checked arena space and copy bytes directly. Literal matching/equality
check lengths before CMPSB, and concatenation/tails use MOVSB. Helpers are emitted
only when used; comparisons alone do not introduce heap startup. A future collector
must recognize the fixed interior String value pointer, and current allocation is
still bounded with no collection.

Upstream probes established that empty-prefix patterns remain refutable, prefix
tails require names/discards, prefix `as` bindings are legal, and string concat is
legal in guards. We implemented those rules and compare Unicode bytes exactly,
without normalization. Literal byte-array string segments default to UTF-8;
nonliteral strings require the explicit option. Codepoint patterns remain open.

The implicit Result type uses reserved names independent of module paths. Local
types/aliases and constructors shadow their respective prelude names separately;
qualified module access does not re-export the prelude. The definition collector
indexes its constructors after user types, preserving prior constructor tags and
emitting nothing for unused definitions. Generic Result callbacks and `use` are
covered, including an Error that skips its continuation entirely.

Malformed UTF-8 is rejected before scanning. The owned validator handles overlong
sequences, surrogates, invalid continuations, truncation and the scalar upper bound.
Independent fatal-decoder checks cover every single byte, boundary sequences and
1,000 deterministic samples. We also compiled the validator's actual Gleam source
with this compiler and executed it natively on eleven valid/invalid inputs. This
is an actual owned-component bootstrap step, not a complete compiler rebuild.

The initial baseline had 381/382 checks passing: the single old rejection expected
String equality to be unsupported. That obsolete negative was replaced by positive
string oracles. New fixture diagnostics and redundant-literal warnings in oracle
source were corrected before qualification. Final evidence is 437 checks and 173
fresh upstream comparisons; pure return-value string oracles additionally compare
actual Unicode/newline output. The 1,852-byte example has recorded ASM, all eleven
older binaries retain their hashes, and repeated concat exhausts the arena safely.

Float/UtfCodepoint, remaining pattern forms, non-string structural equality,
inference, native IO and memory collection remain necessary work. The compiler is
still explicitly bootstrapped through Gleam/Node; no installed tool was replaced.

## Multiple subjects, alternatives and native core — 2026-11-07

An upstream execution probe settled the critical alternative/guard rule: matching
`#(1,9)` against `#(n,_) | #(_,n) if n>5` returns 9. Guard failure must retry the
next alternative with its different bindings. We kept one shared body and copied
each matched row's bindings into canonical frame slots before evaluating its
guard. Subjects are saved once left-to-right on the stack, without an implicit
runtime tuple. Existing simple single-subject IR/bytes remain unchanged.

Alternatives must have the same variable names/types. Known-variant facts are
intersected across them, preventing a first alternative's constructor knowledge
from wrongly authorizing a field access on a later variant. Guard-only captures
and callbacks returned from a selected alternative retain the chosen values after
the factory returns. Names are scoped independently for each later arm.

The new coverage matrix preserves correlations across constructor products instead
of checking each subject independently. It specializes finite Bool/tuple/list/ADT
constructors and removes unconstrained recursive columns. Guarded rows never count.
Negative fixtures include diagonal-only Boolean coverage, list holes and invalid
row arity; independent checks enumerate all 16 subsets of concrete two-Bool rows
and 48 deterministic wildcard matrices over three Bool subjects. Infinite domains
and the legacy single-case coverage path remain explicitly conservative.

All 437 preexisting tests passed before adding the new fixtures. Final evidence:
479 tests and 213 fresh upstream comparisons, with all twelve earlier executable
hashes unchanged. The new stack-only example has recorded guard-retry ASM and is
1,146 bytes; no timing claim follows from its size.

A meaningful owned-source step now works: the entire actual core.gleam module
compiles natively, including previously blocked multi-subject nth and alternative
string-prefix classification. The tracked driver exercises representative list,
string, byte, lookup/map/nth/put and error behavior. Native outputs are compared
with the current upstream-compiled core functions. Source/driver/executable hashes
and the 12,064-byte core-plus-driver result are preserved separately. This is not
the whole compiler or proof of stage-1/stage-2 self-hosting. Structural equality
for the compiler's data types is the next language barrier; native IO, remaining
semantics and owned memory/runtime work remain necessary afterward.

## Structural equality and native compiler components — 2026-11-08

We added a typed comparison graph instead of comparing object pointers or generic
words. Registering each shape before its children supports regular recursion;
constructor tags select the correct fields. Tuples, lists, concrete generic ADTs,
Result, strings and byte arrays now compare by value. List tails loop in native
code and a 10,000-cell check passes; recursive nested fields still use stack.
Comparison does not allocate. Erased stored types, functions and expanding shape
graphs remain explicit rejections, with a 128-entry expansion bound.

Inference holes needed care: the merged operand type supplies missing list/Result
information, while genuinely unreachable fields trap if ever visited. No unknown
field is silently treated as an Int. Phantom parameters need no runtime layout.
Three obsolete pending-equality rejection tests were removed and replaced with
positive and negative semantic coverage. Final evidence: 516 tests, 246 fresh
upstream comparisons, a 2,602-byte example and thirteen unchanged older binaries.
The emitted instructions show tag-before-field checks and a list-tail back-jump.

Compiling our actual definition collector exposed a namespace bug: its local
`types` list shares a name with an imported module. Upstream selects a real local
record field when available and otherwise falls back to the module member. We
implemented that distinction, including private-member checks, non-callable field
priority, guards and captures; eight fresh upstream fixtures verify it.

The entire type-system module now runs natively with its core/AST dependencies and
a bounded driver (24,916 bytes), comparing recursive Type values and exercising
merge/infer/substitute/variables. The entire equality planner runs with its actual
definition collector and dependencies (48,175 bytes), producing the expected
three-node recursive Tree plan. Both receipts compare actual native output against
upstream-compiled owned modules, and retain source/driver/artifact hashes.

A complete compiler API probe remains rejected, not self-hosted: its checker uses
`ReplaceField(a.Lambda(_, _, _) as e)` at line 1437 and the parser does not yet
accept nested `as` patterns. The exact error and source hashes are preserved in
`evidence/complete-api-equality-probe.json`. Next is that concrete pattern gap,
followed by whatever actual whole-source probes expose. Native IO, runtime memory
work and a genuine stage-1/stage-2 rebuild remain unproven; no installed compiler
or crew process was changed.

## Nested aliases clear the next whole-source blocker — 2026-11-08

The complete compiler probe identified a real source need rather than a guessed
feature list: `ReplaceField(a.Lambda(_, _, _) as e)` in the checker. We added an
explicit AliasPattern through parsing, resolution, checking, coverage, capture
analysis and lowering. The whole binding reuses its existing subject slot; the
inner matcher still checks tags and extracts fields. Constructor facts belong to
the alias only when proved, and common alternative facts are still intersected.

Thirty new fixtures exercise nested values, lets,
qualified constructors, guard retries, multicolumn coverage, returned captures,
string/prefix/whole-bit-array aliases and error paths. Independent upstream probes
confirmed that discard alias names and chained aliases are syntax errors, while
`"ab" as prefix <> tail as whole` binds both prefix and complete subject. A first
verification attempt caught my use of the symbol-only expect helper for the word
`as`; the parser was corrected before qualification. Another oracle check showed
that upstream considers an unguarded literal-True case exhaustive; the negative
coverage fixture now uses an unknown Bool parameter to test its intended rule
instead of relying on that unsupported constant specialization.

The repeatable whole-source probe now identifies only the assembler as a frontend
failure: its negative displacement boundary uses magnitude 2_147_483_648, beyond
our current positive literal limit. Every other compiler module lexes/parses;
this does not yet prove whole-project typechecking, native execution, native IO
or a compiler rebuilding itself. The new probe retains source/driver hashes and
its actual diagnostic separately from the previous alias rejection.

Final alias qualification: 546/546 tests and 276/276 fresh upstream comparisons.
The example is 884 bytes with inspected whole-value slot reuse, no dynamic loader
or shared libraries, and fourteen earlier examples remain byte-identical. All
three owned core/type-system/equality-planner native checks pass again; their new
receipts retain current source hashes separately from the prior milestone.

## The compiler API executes natively — 2026-11-08

The next actual whole-source rejection was the assembler's negative 32-bit
boundary. We widened decimal literal magnitudes to 2^53-1, keeping bootstrap JS
exact and rejecting larger inputs before arithmetic. A subtle accumulation issue
needed grouping: `acc*10+c-48` can round at the safe boundary before subtraction;
`acc*10+(c-48)` remains exact. Native arithmetic is still checked signed 64-bit.
This is a deliberate supported bound, not silent full-range compatibility.

Wide pattern constants also need different instructions. CMP r64,imm32 sign-extends
its immediate; blindly truncating would make 4_294_967_296 match zero. Small
patterns retain their original bytes, while wider constants load RDX with movabs
and compare the entire register. Tests cover positive/negative word boundaries,
near-2^53 adjacent digits, nested patterns and signed/unsigned byte-array fields.

With parsing cleared, the full API rejected free_names.statements: [] plus the
Bind/Evaluate head cases really are exhaustive, but the legacy list check could
not combine their nested constructors. We kept its fast path/diagnostics and
reused the existing constructor-product matrix with one subject column. Guarded
rows still do not count and missing combinations still fail. No emitter IR or
runtime matching rewrite was required.

The next attempt hit RangeError/Maximum call stack size exceeded in core.append
while constructing the full code stream. Reversing the prefix and tail-recursively
prepending it to the suffix makes the bootstrap traversals stack-safe. It preserves
order and suffix sharing; a 50,000-cell bootstrap regression and 10,000-cell native
check verify this. The tradeoff is an extra intermediate prefix and native stack
use until TCO; this is correctness/resource handling, not a speed claim.

The complete actual compiler API then compiled into a 497,741-byte native image
and ran, reporting a 380-byte output. We did not stop at a length: the stronger
driver emits every generated byte. Its 498,418-byte image compiled two programs
natively, yielding 380- and 745-byte ELF files exactly identical to bootstrap
compiler output. Both execute with expected outputs (`7` and `7,10`). The second
program uses a wide pattern and tuple alias. No upstream compiler, Node, libc,
assembler/linker or VM executes inside the native compiler path. The bootstrap
still creates the initial native image; native file IO/CLI and a compiler actually
rebuilding itself are separate remaining requirements.

The byte-emission driver's initial empty/nonempty byte cases needed an explicit
fallback for non-byte-aligned BitArrays, which remain possible in the type's
full domain. It now emits an invalid-stream marker on that unreachable-in-ELF
path rather than pretending byte-array coverage handles arbitrary bit lengths.
Current proof records include actual source/driver hashes and emitted-program
comparison/execution, not just successful parsing or source generation.

Final qualification is 572/572 tests and 297/297 fresh upstream comparisons,
including 21 new integer/coverage fixtures, three literal safety regressions and
two append regressions. All fifteen older example hashes remain unchanged. The
662-byte wide-pattern example has retained actual movabs/cmp instructions. A fresh
full verifier run repeats the two native compiler output/execute checks and
inspects the compiler/child ELF headers. No final-speed claim follows from the
compiler's 498,418-byte API-plus-driver size or the children matching bootstrap.

Next: a native argument/source-file entrypoint with robust IO, then compiling the
complete compiler input natively at scale and a real identical-source rebuild.
Arena growth/collection and native TCO remain measured-scale concerns, especially
the two-pass append and existing byte concatenation; they are not silently solved
by successful bounded native compilation.

## Bounded native CLI and real syscall qualification — 2026-11-08

We specified a concrete command before implementation: source module path relative
to an explicit source root (default cwd), a new output, help/version and explicit
error codes. This differs intentionally from the bootstrap's implicit dirname
root. We kept compiler policy in a pure Gleam request state machine: Arguments,
ReadSource, WriteExecutable and Finish. A small owned emitted effect runner reads
kernel argv and calls typed policy callbacks. No placeholder function replacement,
foreign compilation strings, upstream subprocess or VM is involved.

The build entry validates constructor owner, field types AND label order, plus
callback signatures before emitting the runner. Two String fields can swap places
without a type error; the label-order check specifically prevents that ABI bug.
Kernel argument bytes are UTF-8-validated before forming owned Strings. Reads use
root descriptors/openat2 restrictions, regular-file checks and complete-read loops.
Writes use an exclusive sibling, complete writes, chmod/fsync/checked close and
renameat2 NOREPLACE publication. Existing files/directories/symlinks are preserved;
normal failures clean owned temporary files. Crash/directory durability and
termination cleanup are deliberately not promised. Linux close errors are not
retried. The syscall ABI references are linked in NATIVE_CLI_SPEC.md.

First-build failures were ordinary compiler-subset/assembly diagnostics: the
entry suffix bit-array pattern needed explicit byte literals, and entry dispatch
labels needed their own namespace to avoid colliding with IO helpers. These were
corrected before execution qualification. A proposed 1 MiB input cap was then
shown unsafe: a 33 KiB comment-heavy source crashed the native frontend stack,
while 24 KiB passed. The exact old artifact and input hashes/results are retained
in native-cli-initial-size-failure.json. We reduced the qualified cap to 16 KiB;
a boundary test verifies 16,384 bytes compile and 16,385 fail before parsing.
Whitespace runs now use a separate small lexer frame instead of recurring through
scan's much larger frame. This is a bounded resource fix, not general native TCO
or full-size reliability. A test caught that my initial constant edit had changed
the diagnostic but missed the formatter's underscored numeric literal; the actual
limit/chunk constants were corrected and boundary-qualified before completion.

All sixteen example programs now compile through the native file-based executable,
with empty PATH, exact bootstrap byte comparisons and successful child execution.
The 59 CLI-specific tests also cover Unicode paths, a multi-chunk file, invalid
UTF-8/arguments/sources/imports, cycles, symlinks/directories/FIFOs, oversized files,
existing-output preservation, concurrent publishers and preexisting temporary files.
Strace injects EINTR at eight syscall sites and explicit IO/publication/close errors.
A separate Python/ctypes ptrace DEVELOPMENT harness shortens actual kernel request
sizes: 4 real positive short reads and 54 real positive short writes still produce
the expected ELF. Only the initial execve is observed; the native process does not
launch another program. The target contains no ctypes, libc, strace or Python.

The native CLI is 582,442 bytes; the current embedded API-plus-driver is 573,503
bytes. These are different entrypoint artifacts. Both ELF headers show no dynamic
loader/segment and an RW, non-executable stack. Selected actual entry/read/write
instruction windows are retained. Final qualification passes 631 tests and 297
fresh upstream comparisons; all sixteen older example hashes remain unchanged.
The earlier API receipts are preserved rather than rewritten with new source.
A runnable, ignored local artifact is out/gleam-native. No installed Crew/compiler
or unrelated session was changed; generated images stay out of Git.

The next measured work is full-size stack/allocation reliability and lifting the
source cap. A native self-build route must invoke cli_builder.build to retain the
compiler effect runner; the ordinary program compile path does not supply that
entry. Stage-2 rebuilding remains unproved. Subjective milestone progress moves
from 65% to 70% for delivered bounded CLI/IO, not full-language compatibility.

## An interactive, evidence-linked roadmap — 2026-11-08

Jay asked to turn the eight-step plan and its specs into something interactive.
We kept it in the private repository as a portable offline HTML document: eight
expandable workstreams with Spec, Acceptance and Evidence tabs, searchable text,
core/expansion filters, next actions and versioned links. The stage status and
70% subjective estimate are readonly baseline facts. Acceptance marks and notes
are personal browser review only, persist locally and can be exported; they do
not mark compiler work complete or create another task database.

The structured roadmap manifest feeds a small standard-library Python generator.
It validates stages/links and agreement between actual verification receipts,
derives the 631/297/16-example/582,442-byte metrics and embeds the snapshot. Browser
code belongs only to documentation; compiler/runtime dependencies are unchanged.
GitHub renders HTML source, so the instructions explicitly show opening the local
file or serving a loopback preview. No public deployment is implied.

We also wrote the next full-size reliability spec. It preserves the known
33,036-byte failure and 24,036-byte success, inventories the actual 230,817-byte
compiler graph, and separates stack attribution, a candidate self-tail-call fix,
allocation measurements and a qualified cap increase. Later workstream specs stay
outlines until evidence warrants detailed design. Self-hosting remains unproved.

Ten real-browser check groups pass in Chromium: stage/metric rendering, filtering,
search, keyboard tabs, persistent inert notes, export, mobile/touch layout,
malformed/blocked storage, no-JavaScript fallback and zero external HTTP requests.
Desktop/mobile screenshots were visually inspected and remain in ignored out/.
The dedicated UI receipt retains source/screenshot hashes. Compiler qualification
continues to refer to the prior source baseline, rather than counting these UI
checks as newly compiled language cases.

## The compiler rebuilds itself — 2026-11-08

We reproduced the old large-comment crash using frozen ba5b3c8 target source and
an explicitly higher diagnostic cap, rather than removing a production guard.
A bounded ptrace probe found the actual cause: all 256 sampled frames were the
UTF-8 validator, with 272-byte locals and 296-byte stride. The 8 MiB stack was
exhausted with only 1,173,024 arena bytes allocated. Zero-byte symbol labels and
exact artifact hashes tied these observations to real emitted instructions.

Direct self-tail lowering fixed that frontier. Arguments are evaluated left to
right before replacing parameters; a jump returns to the body after its prologue.
The identical diagnostic input now compiles, and million-iteration regression runs
finish under a 64 KiB stack. Ordinary recursive calls and closure boundaries remain
explicitly ordinary; this is not general tail-call optimization.

The full compiler graph then hit the arena boundary. Raising a diagnostic arena
to 512 MiB still failed: closure helpers repeatedly copied a growing instruction
prefix. Balanced byte concatenation plus reverse closure accumulation removed the
measured copying frontiers. These failures remain in the scale receipt; we did not
replace them with successful runs or treat capacity alone as an optimization.

Production limits are now 128 KiB/source and a bounded 512 MiB compiler arena,
while ordinary output programs retain 64 MiB. A native --build-compiler route
retains the owned effect-runner entry. Two native rebuilds from the same frozen
26-module source are byte-identical to the initial native seed: 592,047 bytes,
SHA256 752240b4e5ab9bb926e171614468790d4a21f168ef3a70d04e9c6d0897e98fbb.
One rebuild allocated 368,525,376 bytes and peaked at 360,320 KiB RSS. These are
resource observations, not comparative speed benchmarks. No GC or growth exists.

The rebuilt stage-3 compiler passes all 317 corpus cases, including 198 accepted
outputs byte-identical to bootstrap and 119 controlled rejections. A changed-version
source control produces the correctly changed image, matching a fresh bootstrap
reference. Full qualification passes 657 tests and 317 fresh upstream comparisons;
59 targeted native IO checks preserve syscall/publication behavior. The first
self-hosting milestone reaches its defined finish line; full upstream compatibility
is still false. All earlier component proofs remain historical.

Jay next suggested GCC-style look-ahead and register spilling. We will measure
frame traffic first, then retain values in registers where the actual clobber and
evaluation-order contracts allow it. No borrowed optimizer, external backend or
runtime dependency is introduced. Correctness and actual ASM stay the criteria.

## Look-ahead, spills and a caught grammar mismatch — 2026-11-08

Jay suggested look-ahead and register spilling. We first recorded actual frame
traffic, then limited the optimization to proven leaf right operands. RCX retains
the left word only when the right cannot clobber it; calls keep their spills.
An identical-target comparison removes 260 push/pop pairs and 451 static named-
function instructions, saving 334 bytes. Frame-slot traffic is unchanged; these
counts are not a runtime benchmark or a whole-function allocator.

The fresh upstream comparison rejected our expected result for a new nested-effect
case: mark(3)-1 begins a signed-literal expression after the call. The prior native
compiler had the same mismatch. We retained that failure, added token-end tracking
and separate adjacency/spacing/newline/comment/underscore regressions. Correct
subtraction is tested with its explicit spacing. We did not hide the failing input
by only rewriting it into a passing fixture.

Final qualification passes 677 tests and 333 independent upstream comparisons.
Stage 3 natively compiles all 333 corpus cases, and two native self-rebuilds are
again byte-identical. Current native image: 596,782 bytes,
SHA256 8d9ff75ac0eabe36662e6c7bd3bf8291af145ee054db7d706ee178d09678db18. The original first self-hosting receipts
remain intact; leaf-register-* records this new increment. No runtime dependency,
installed Crew executable or unrelated process was added or replaced.

## Sharing stack slots across sibling arms — 2026-11-08

The next bounded allocation fix follows control-flow exclusivity: sibling case
arms share local slots, retaining the maximum frame requirement. Outer locals,
subjects, canonical bindings and copied closure captures remain protected; tests
exercise nested branches, failed guards, escaped closures, heap values and tail
parameter replacement. No whole-function allocator or new runtime is introduced.

On identical db47d61 compiler source, 95 of 384 named frames shrink. Their aggregate
reservation falls from 36,800 to 26,112 bytes; the lexer drops 880→208 and parser
pattern routine 944→192. Executable length is unchanged for that fixed source.
A separate actual 64 KiB stack run shows non-tail input 600/terminal arm 7 fails
with the previous 208-byte frame but returns 180285 with the new 32-byte frame.
The initial signal is preserved alongside the success; neither is a speed claim.

Full qualification passes 687 tests, 341 fresh upstream comparisons and all 341
native corpus cases. Two native self-rebuilds remain exact. Current image:
597,813 bytes, SHA256 5c2573e87bd01e7c70c430fcd5304cfe83f4df23e09e87991aacfaaf3656836a. The own implementation
adds source/code even though fixed target frames shrink. Earlier milestone evidence
remains unchanged; branch-slots-* records this increment separately.

## Typed regions, liveness and actual register spills — 2026-11-08

We introduced an owned typed machine plan for call-free integer expressions,
including explicit register uses/definitions and condition Flags. A three-register
pool retains nested values; higher pressure spills and recovers them through a
reserved scratch register. Backward liveness removes dead moves while retaining
traps and stack balance. Calls/control flow stay outside: whole-function CFG
allocation is still unfinished. Compiler logic remains Gleam with no new package.

Independent stress validation generates 100 expressions in one program and checks
BigInt expectations, upstream execution and actual native output/bytes. 68 regions
spill, maximum operand pressure seven. A separate overflow-before-zero test ensures
apparently dead arithmetic cannot lose its trap. The fixed compiler-source image
shrinks 116 bytes, with 15 fewer push/pop pairs and 54 fewer static instructions;
this is modest emitted-code evidence, not a speed benchmark.

Full qualification passes 702 tests and 351 fresh upstream comparisons, all 351
rebuilt-native corpus cases and two exact native self-rebuilds. Current compiler:
613,842 bytes, SHA256 df8df2222b511f403f7488472dada651a0a8a5c8010a199fe88046e8e039bb7b. Its new implementation
naturally adds source/code beyond that fixed-target saving. An old hardcoded
disassembly receipt path was corrected; 59 IO tests were rerun with unchanged
compiler source/image and the initial receipt preserved. Earlier milestone
receipts remain intact under their original names.

## Caller saves across named integer calls — 2026-11-08

The typed plan now models named calls and their full allocatable-register/flags
kill mask. It saves pending ancestor operands before evaluating arguments with a
fresh pool, stages arguments in source order, copies the return value before
restoring saved operands and keeps effectful calls even when results are dead.
This preserves the existing owned stack ABI and direct self-tail reentry path.
Indirect/non-integer calls and general control-flow allocation remain unfinished.

715 tests and 361 fresh upstream comparisons pass; all 361 cases also pass through
the rebuilt native compiler. Two native self-rebuilds match the seed. The separate
call stress program contains 100 expressions, 286 named calls and 386 modeled
ordered effects; native/upstream/model results and native/bootstrap bytes agree.
The previous pure stress program's source and output image are unchanged.

No fixed compiler-source image or instruction-count improvement is observed for
this foundation. Result placement/coalescing still deserves measurement; we do
not infer a speedup from the new capability. Current compiler image:
617,676 bytes, SHA256 38eaaeb14bd30e616378134367ed0fe4fdebc6c19868c4cd30de18fd69b4258e. No runtime dependency
or installed Crew/compiler executable was added or replaced. All prior receipts
remain preserved under their original milestone names.

## Scalar CFG joins, qualification and honest benchmarks — 2026-11-08

We added real machine labels/jumps, signed scalar comparisons, short-circuit
expressions and supported scalar cases. Successor-aware liveness unions both
branches and converges on backedges. The join returns RAX before restoring pending
outer operands; unsupported patterns still use the existing correct lowering.
729 tests, 371 upstream/corpus comparisons and two exact native rebuilds pass.
Pure, call/effect and branch stress programs each contain 100 generated expressions.

Two aggregate verifier timeouts are retained. The first exposed applying graph
analysis to straight-line plans; their qualified linear pass was restored. The
multi-stage self-host proof also needed an aggregate allowance of 180 rather than
60 seconds; individual process limits were not loosened. These are preserved
findings, not a fabricated successful original run.

Repeated pinned-child benchmarks compare previous/native current versions on
identical frozen source and checked runtime inputs. Short-run wall times differed
even for byte-identical controls, so tenfold longer workloads were measured too.
The final current-source self-build median is 8.75 s elapsed / 7.42 s CPU and
390.8 MiB peak RSS. Generated branch code is smaller and about 2% lower CPU here;
short-circuit code is smaller but about 3% higher CPU. No broad speedup follows.
The detailed raw distributions, source/image/harness hashes and limits are retained
in BENCHMARKS.md and control-flow benchmark receipts. Current image: 637,999 bytes,
SHA256 3a8063b7582cb04e53c7443110403dc80f7c757fab0a893add0089a367ca8b65. General whole-function and upstream-language
work remains separate; no installed Crew/compiler process was replaced.


## Remove allocation before adding GC — 2026-11-08

Rather than infer garbage from the 391 MiB rebuild peak, we traced the arena
cursor at compiler phase boundaries in a new owned child. ELF packaging allocated
26 MB for about 638 KB of code: the byte-count helper constructed a 40-byte suffix
descriptor at each step. Assembly repeatedly paid the same cost.

A typed structural recognizer now identifies only the exact effect-free unit-step
byte-count recursion, regardless of function name, and emits a descriptor-length
load plus checked addition. Guards, effects, changed increments/bases and different
callees retain ordinary lowering. Actual ASM checks verify the 40-byte function
contains no loop/allocation call; aliases, borrowed tails and overflow are tested.

Same-input allocation falls 409,183,952 → 338,729,536 bytes (17.2%); peak RSS falls
390.8 → 323.6 MiB. Five untraced repeated runs show median CPU 7.522 → 5.015 s,
with wall variation retained. No collector or third-party dependency was added.
Correctness: 744 tests, 383 upstream comparisons and byte-identical native rebuilds.
The compiler grows to 644,591 bytes because it includes its own recognizer.

This is measured waste removal, not full heap liveness or complete Gleam support.
Project linking is now the largest selected phase and is the next profiling target.
Crew CLI updates remain with their separate owner. [Method and evidence](MEMORY.md).


## Measure linking before changing its representation — 2026-11-08

A narrower native trace divides the 121.7 MB linking phase into resolution 60.4 MB,
lexing 47.9 MB, parsing 12.1 MB, definitions 1.0 MB and other work 0.37 MB. Within
resolution, member lookup alone accounts for 35.3 MB exclusive of measured nested
helpers. Its source rebuilds function/constructor lists for every lookup; module
and local-name lookup repeat similar mapping. A second finding is independent:
dependency discovery already lexes/parses all 27 modules, before linking repeats
both. Each pass allocates 59.9 MB. These are allocation volumes, not retained data.
The code generator and runtime remain unchanged. We preserved the detailed trace
hash, additive summary and output verification, and paused the next rewrite to
ask Jay for advice on lookup indexing, parse-once ownership and cursor/span input.
See [MEMORY.md](MEMORY.md) for the complete breakdown and cautions.

## Act on the measured direction, keep the increments reversible — 2026-11-08

Jay's advice was to choose a direction while the architecture is clear, understand
that a sequence of optimizations may later be replaced, and avoid over-planning.
We removed rebuilt lookup lists first, then retained parsed source snapshots.

Direct search preserves lookup order and privacy without allocating parallel name
lists. Resolution allocation falls 60.4 to 10.7 MB. Parse-once carries the existing
immutable source bytes with their AST through loading/linking, preserving raw API
compatibility and unreachable-source behavior. Actual traces show 27 rather than 54
lexer/parser calls. No global mutable cache or invalidation machinery was needed.

Combined with the earlier byte-count rewrite, same-input allocation falls 409.2 to
228.9 MB and peak RSS 390.8 to 218.5 MiB. The current native compiler grows modestly
to 645,969 bytes. The final 748 tests, 383 independent upstream comparisons and
byte-identical native rebuilds pass. These volumes do not prove live heap size;
separate repeated benchmarks retain timing and host variation.

The new GUIDE.md documents installation/bootstrap versus native use, language
syntax/examples, exact supported semantics, module/AST/type-checking architecture,
ASM/register/runtime layout constraints, compiler API, limits and extension rules.
All nine complete Gleam examples execute with checked outputs. Lookup and AST
changes are separate commits so we can revise either when later evidence warrants.
