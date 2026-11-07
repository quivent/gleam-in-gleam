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
