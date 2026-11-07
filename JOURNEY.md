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
