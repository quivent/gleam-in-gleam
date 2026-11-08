# Implementation history and archived working README

> This preserves the working README before its presentation redesign on
> 2026-11-08. Statements of “current” status below refer to their recorded
> milestone. Start with [README.md](README.md) for the current presentation,
> [GUIDE.md](GUIDE.md) for the language and architecture reference, and
> [JOURNEY.md](JOURNEY.md) for the implementation journal.

---

# Gleam in Gleam

A compiler rewrite in Gleam, with direct machine-code generation and **zero
third-party dependencies** as a hard design constraint. No LLVM, Cranelift,
Glance, standard-library package, external assembler, external linker, libc,
or bundled VM is used by the native seed.

**Status: the standalone Linux x86-64 compiler now rebuilds itself.** Two native
rebuilds of the exact frozen compiler source are byte-identical to the initial
native seed. The rebuilt compiler passes all 383 positive/negative corpus cases;
accepted programs match bootstrap executable bytes and run correctly.

**First self-hosting milestone: 100% of its defined acceptance scope.**

```text
[████████████████████] 100% — supported-subset self-hosting
```

This completes the previously defined first milestone, not full upstream Gleam
compatibility. Remaining syntax, value semantics, optimization and targets stay
open in [ROADMAP.md](ROADMAP.md). The source limit is 128 KiB per file; the compiler
uses a bounded 512 MiB arena without GC. Ordinary emitted programs retain 64 MiB.

[Open the interactive eight-step roadmap](docs/roadmap.html): expandable specs,
acceptance review, evidence links, search and local notes. Open the checkout HTML
in a browser; GitHub shows its source. [Preview/update instructions](docs/README.md).
The [full-size reliability record](FULL_SIZE_RELIABILITY_SPEC.md) preserves the measured failures and fixes.

## What actually runs

The bootstrap remains available for development:

```text
Gleam compiler source (this repository)
    → existing Gleam 1.19.2 bootstrap compiler
    → generated JavaScript + Node host-IO bridge
    → input Gleam source modules
    → native ELF bytes
    → Linux kernel executes the program
```

The final two steps do not use Node, Rust, Gleam tooling, libraries, a dynamic
loader, an assembler or a linker. The standalone native CLI also executes without
the bootstrap after its initial native image is generated.
A 601-byte Fibonacci executable is **a generated example program**,
not the size of a completed compiler.

Observed bootstrap chain:

```text
Stage 0: existing Gleam toolchain generates the bootstrap implementation
Stage 1: bootstrap emits our standalone native compiler
Stage 2: stage 1 recompiles the exact frozen compiler source
Stage 3: stage 2 repeats that rebuild; all three native images are identical
```

The native image is **645,969 bytes**, SHA256
`7bb657841b0505ce9d44dba875c5654cb7d3dee23a65968f205f22e8b29b0b5f`.
The qualification also changes a version literal in an isolated source copy:
the native compiler emits the correctly changed image, matching the bootstrap.
This checks that the rebuild consumes source rather than copying its own image.
See [SELF_HOSTING.md](SELF_HOSTING.md) and the [rebuild receipt](evidence/parsed-snapshot-native-rebuilds.json).

Read the [complete implementation and language guide](GUIDE.md) for syntax,
CLI usage, architecture, representation, verification and explicit limitations.

## Run the current implementation

Build the native CLI once, then compile files directly:

```sh
gleam build --warnings-as-errors
mkdir -p out
node build-native.mjs out/gleam-native
./out/gleam-native fibonacci.gleam out/fibonacci-native --source-root examples
./out/fibonacci-native
./out/gleam-native modules.gleam out/modules-native --source-root examples
./out/modules-native
```

The outputs print `55` and `14,8,3` respectively. SOURCE is relative to the chosen
source root (default current directory), rather than the bootstrap's implicit
source dirname. Output must be new: completed files are published without replacing
an existing file, directory or symlink. The runtime uses direct Linux syscalls,
including openat2 and renameat2; unsupported operations fail explicitly.

The CLI bounds each source file to **128 KiB** and a graph to 256 files,
refuses source symlinks and nonregular files, and validates UTF-8 arguments.
Direct returned self-calls loop after the prologue; mutual/indirect calls and
continuation callbacks retain ordinary calls. Balanced byte concatenation and
reverse closure accumulation avoid two measured quadratic copying paths.
The compiler arena is 512 MiB without GC or growth. The first milestone native self-rebuild used
368,525,376 arena bytes and peaked at 360,320 KiB RSS; this is a resource observation,
not a speed benchmark. Ordinary emitted programs still use a 64 MiB arena.

Rebuild the compiler natively into a new output:

```sh
./out/gleam-native --build-compiler out/gleam-native-stage2 --source-root src
./out/gleam-native-stage2 --build-compiler out/gleam-native-stage3 --source-root src
cmp out/gleam-native out/gleam-native-stage2
cmp out/gleam-native-stage2 out/gleam-native-stage3
```

Keep inputs unchanged across these commands. `python3 verify.py` freezes inputs,
checks both rebuilds and qualifies the rebuilt compiler. See
[NATIVE_CLI_SPEC.md](NATIVE_CLI_SPEC.md) for IO and explicit bounds.

The native tests require strace, objdump, Python and ptrace permission as
**development-only fault-injection/inspection tools**. The native compiler itself
does not load those tools or call another process.

The original bootstrap entrypoint is also available:

Prerequisites **for development/bootstrap only**: upstream Gleam 1.19.2, Node
22+, and Linux x86-64 to execute native outputs. No package download is required:
`gleam.toml` has no dependencies and `manifest.toml` has an empty package list.

```sh
gleam build --warnings-as-errors
node --test test/native.test.mjs
mkdir -p out
node bootstrap.mjs examples/fibonacci.gleam out/fibonacci
./out/fibonacci
```

The program prints `55` and exits zero. The bootstrap refuses to overwrite an
existing output. Use a new destination for each compile, or remove only your
own previous output intentionally. On this development host, the verified
bootstrap compiler is installed privately at:

```text
/home/oscillihue/.local/share/gleam-native/bootstrap/1.19.2/gleam
```

The downloaded official Linux-musl archive's SHA256 was verified:
`2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f`.
No system or Crew compiler was replaced. The private compiler install is
bootstrap tooling, not a dependency to ship with the final compiler.

A local multi-file example uses the same command:

```sh
node bootstrap.mjs examples/modules.gleam out/modules
./out/modules
# 14, 8, 3 on separate lines
```

The default source root is the entry file's directory. For a nested entrypoint in
a supported source tree, select its root explicitly:

```sh
node bootstrap.mjs path/to/src/app/main.gleam out/program --source-root path/to/src
```

The bridge loads only requested local `.gleam` modules and refuses symlinks that
escape that root. It still refuses to overwrite an existing executable. There is
no package download or external object-file linker in this implementation.

To repeat the separate embedded-input native compiler API proof:

```sh
node test/probe-compiler-api.mjs
```

This compiles the reachable compiler API modules with a tracked test driver,
executes the native image, extracts two generated ELF files, compares them byte-for-byte
with bootstrap output, and runs both. It does not invoke upstream compilation
inside the native compiler, replace an installed compiler, or prove a self-rebuild.
See `evidence/complete-api-native-cli-probe.json` for current source/driver/artifact
hashes; the earlier wide-integer receipt remains historical.

## Current implementation

All parsing, checking, instruction selection, relocation and ELF writing live in
Gleam. `bootstrap.mjs` supplies argument/file IO and converts the bootstrap's
BitArray representation. It follows file requests returned by the Gleam parser and enforces the selected
source root. Dependency ordering, name resolution, visibility, type checking and
code generation remain in Gleam; the bridge performs no language compilation.

| Module | Responsibility |
| --- | --- |
| `native/core` | Compiler-owned list, byte and diagnostic utilities |
| `native/utf8` | Compiler-owned scalar UTF-8 validation |
| `native/prelude` | Reserved implicit Result/Ok/Error definitions |
| `native/string_runtime` | Owned byte comparisons, checked concatenation and prefix-tail copies |
| `native/lexer` | Tokens, comments, decimal literals, UTF-8 string bytes |
| `native/ast` | Language seed syntax types |
| `native/parser` | Precedence, functions, bindings, calls and case expressions |
| `native/coverage` | Constructor-product coverage for multiple subjects and alternatives |
| `native/check` | Typed expressions, constructor inference, scope and exhaustiveness |
| `native/definitions` | Nominal types, constructor identities and public interfaces |
| `native/type_system` | Scoped constructor/function substitution and function types |
| `native/equality` | Recursive typed structural-comparison shape graphs |
| `native/equality_runtime` | Owned native comparison helpers and iterative list tails |
| `native/free_names` | Lexically scoped free names for copied closure captures |
| `native/bit_options` | Static byte-segment options and pattern/construction validation |
| `native/labels` | Constructor labels, positional validation and declaration ordering |
| `native/x64` | Direct instruction selection, stack frames and syscall helpers |
| `native/heap` | Bounded arena allocation through direct Linux mmap |
| `native/assembler` | Internal labels and signed relative relocations |
| `native/elf` | ELF64 image and program headers, non-executable stack |
| `native/project` | Import graph, local module names, visibility and lexical resolution |
| `native/compiler` | Single-file/project compile pipeline |
| `native/cli` | Pure arguments, source graph and output request policy |
| `native/cli_runtime` | Owned Linux effect runner, validated request ABI, syscall loops |
| `native/cli_builder` | Explicit stage-0 build entry for the native compiler CLI |

The internal assembler is written in Gleam and emits bytes. It is not an
external assembler dependency. The small generated integer/string print
helpers are part of the generated program's code, not a separately installed
runtime. Automatic memory management for future allocated values will also
need compiler-owned code; zero external dependencies does not mean that memory
management can be omitted.

Implemented seed features: explicitly typed functions and parameters,
forward/recursive calls, local bindings and shadowing, Int/Bool/Nil/String values, integer operations, comparisons, short-circuit booleans,
case matching, exhaustiveness checks for this subset and primitive
value printing. Typed tuples, tuple indexing/destructuring, lists,
list spreads and nested tuple/list patterns are supported. Unlabelled calls,
tuple fields and list heads preserve left-to-right evaluation order. Labelled
constructor arguments are arranged and evaluated in declaration order, matching
the upstream compiler's actual behavior. Division/remainder by
zero return zero. Unsupported constructs produce diagnostics rather than
delegating compilation elsewhere.

Custom types now support positional/labelled constructors, zero-field values,
recursive/mutually recursive definitions and nested constructor matching inside
lists/tuples. Constructor fields are checked against their declared nominal
types, not just their memory shape. Public interfaces cannot expose private
types. A zero-field constructor is a value rather than a callable function.
Known top-level constructor identity is retained across simple local bindings,
including annotations, for let-pattern/case checking. Runtime tag checks remain
in the emitted code; this is semantic checking, not a tag-check optimization.

Generic custom types support scoped type parameters, nested/recursive type
applications, repeated-parameter consistency and constructor argument inference.
Type arguments are checked at compile time and do not add runtime type objects
or change the one-word field layout. Labelled constructor calls/patterns support shorthand
and pattern spread; duplicate/unknown labels and positional arguments after
labels are rejected. Record access works for fields common in name, position and
declared type across all possible variants, or for a known constructor.

Generic functions with explicit signatures are checked using rigid body type
variables and fresh bindings at direct global call sites. Direct self-recursion
keeps the current signature rigid, matching the upstream acceptance checks.
Function types, monomorphic named function values, aliases, returned functions,
generic higher-order parameters and callbacks in records are supported.
Anonymous functions copy their free local values into arena-owned descriptors;
returned and nested closures retain their captures after the factory returns.
`use` lowers to an appended callback, including tuple-pattern, zero-argument and
multiple-argument callbacks. Parameter annotations or sufficiently resolved
expected function types are required; this is not general type inference.
Expected types flow through annotated bindings, function results, constructor
fields and case branches. Callback argument checking can use type information
from other arguments without changing runtime evaluation order.

Every first-class function now uses `[size][tag=0][code pointer][captures...]`.
Named functions also allocate descriptors; the earlier raw-pointer ABI is
historical. Indirect calls save the descriptor before evaluating arguments,
check its tag, and call its static code pointer. Captures hold copied value
words, never pointers to a returned stack frame. See [ASM.md](ASM.md).

Record updates (`Record(..original, field: value)`) save and evaluate the original
once, then construct a new immutable record. Retained fields constrain generic
parameters; overwritten fields may change those parameters when other retained
fields do not constrain them. Phantom parameters remain fresh. Replacement fields
use declaration order, including label shorthand. Multi-variant updates require
the original's constructor to be statically known and match the named constructor;
unknown/wrong variants and zero-field update constructors are rejected.

The first bit-array subset supports byte-aligned integer construction (0..64 bits),
concatenation with `:bits`, endian options and signed/unsigned integer extraction
(8..64 bits). Sizes can be numeric or static `size(N)`. Integer construction
keeps the low requested bits. Nonzero segments evaluate left to right; a statically
zero-width segment is checked but its value is not evaluated, matching upstream.
Patterns check exact/minimum lengths before loading bytes and may bind a final
unsized `rest:bits` or `rest:bytes`. Only `:bits` is irrefutable; the upstream
exhaustiveness distinction is preserved even though this seed only constructs
byte-aligned data. Pattern-only options are rejected in construction.

Arrays own arena payloads; returned slices share bytes and retain an explicit root
owner pointer, preparing for future collection. No collection exists yet. Signed
native Int limits apply: unsigned 64-bit extraction above 2^63-1 exits 70; wildcard
and literal matching still handle such bytes without treating them as negative
unsigned numbers. Non-byte-aligned segments, dynamic/sized-array segments, floats,
UTF-8 codepoint patterns and BitArray printing remain unsupported. Structural byte equality is supported.
String-to-byte construction with `:utf8` is supported, including the default
encoding for literal string segments; nonliteral strings require `:utf8`.

Local module imports support default names and `as` aliases, qualified functions,
function values, custom types, constructors, patterns and record updates. A pure
Gleam project pass rejects cycles/missing modules, resolves lexical shadowing,
checks exported membership and gives every module's declarations distinct internal
names. Identically shaped types in different modules remain nominally distinct.
Module paths/aliases currently require lowercase-initial ASCII components, with
lowercase letters, digits and underscores afterward. Shared dependencies are
linked once in deterministic import order. Unreachable
supplied source content is not parsed or linked.

Lowercase value access respects local shadowing; qualified constructor access and
type/pattern namespaces retain their module meaning. Private helpers remain usable
inside their defining module and inaccessible through an import. This is compile-
time resolution into the existing typed IR and relative relocations, with no
runtime module lookup. A test verifies byte-identical output against an equivalent
single-module program for one fixture; that is not a compiler-speed benchmark.

Type aliases support generic parameters, forward references and imported aliases.
They expand transparently in their defining module's scope before checking and
native lowering. All definitions are validated, including unused aliases;
direct/mutual cycles, wrong arity, duplicate/unbound/discard parameters and unused
parameters are rejected. Recursive nominal types may still refer through aliases
without making the alias itself infinitely recursive. Alias names obey import
visibility, while public-interface privacy follows the underlying nominal types.
A private alias of a public type can appear in a public signature; an alias cannot
hide a private nominal type from that check. No runtime alias wrapper is added.

Case guards support typed Bool conditions with primitive operations, short-circuit
booleans, grouped expressions and local tuple/record access. Pattern matching
precedes guard evaluation; a false guard continues to later arms with the original
outer scope. Guard-only free variables are captured by closures. Guarded arms do
not prove exhaustiveness, even with `if True`, and unreachable bodies are still
checked for type consistency. Calls, bindings and effects are forbidden in guards;
constructor/collection guard forms remain unsupported in this subset. Structural
comparisons use the same typed helpers as ordinary expressions. Integer guards use the same checked native Int arithmetic.

Strings now support dynamic `<>` concatenation, byte-exact `==`/`!=`, literal
matching and literal prefixes with a rest/discard and optional prefix binding
(`"pre" as head <> tail`). Unicode scalar UTF-8 is preserved without normalization;
concatenation and equality work in guards too. Prefix patterns remain conservative
for exhaustiveness/refutable lets even when the prefix is empty, matching upstream.
Returned tails own copied payload bytes, and closures retain their values safely.
String-to-bit-array UTF-8 construction excludes the diagnostic trailing newline.
The lexer rejects malformed UTF-8 source before tokenization.

The implicit prelude now includes `Result(a, e)`, `Ok` and `Error` alongside the
primitive types already implemented. Reserved internal names keep the default Result
nominally shared across modules. Local type/alias/constructor declarations shadow
the corresponding prelude names independently; imported modules do not re-export
implicit prelude members. Prelude constructors use the existing generic ADT layout
and positional arguments. Unused prelude definitions add no target code or change
existing constructor tags. Float and UtfCodepoint are not implemented yet.

Cases support multiple subjects and alternative pattern rows, for example
`case xs, index { [x, ..], 0 -> ... }` and
`"A" <> _ | "B" <> _ -> ...`. Each row must have one pattern per subject.
Alternatives bind exactly the same names with compatible types; facts about known
variants are intersected rather than borrowed unsafely from the first alternative.
Subjects evaluate once from left to right into frame slots, with no synthetic
runtime tuple. Pattern alternatives share canonical binding slots and one body.
If a matched alternative's guard fails, matching retries the next alternative
before moving to the next arm, matching upstream behavior.

A constructor-product coverage pass handles correlated Bool, tuple, list and
nominal constructor columns, including known top-level variants. Guarded rows
contribute no coverage. Infinite domains still need defaults; unconstrained
recursive columns are removed without endlessly expanding their constructors.
Independent truth-table checks cover concrete and wildcard Boolean products.
Nested `|` inside an individual pattern is rejected, as upstream requires complete
alternative rows instead. Ordinary single-subject/non-alternative cases retain
their historical IR and conservative coverage checks.

## Pattern aliases

`pattern as name` binds the entire matched value alongside nested bindings. This
works in lets, case rows and alternatives, including nested constructor/tuple/list
patterns, qualified constructors, whole BitArrays, string literals and string
prefixes. Alias bindings carry the whole value's type and known constructor where
proved, so a matched variant's record fields remain available. Names participate
in duplicate detection, alternative binding consistency, guard scope and closure
capture. Aliases do not widen coverage or make a refutable let irrefutable.

Lowering maps the alias to the existing subject stack slot. It introduces no object
copy or arena allocation. Nested matching still emits its ordinary tests/loads.
Discard alias names and chained `as` forms are rejected, matching upstream syntax.
Aliases inside individual bit-array segments remain outside the supported subset;
aliases around the entire bit array work.

## Structural equality

`==` and `!=` compare tuples, lists, byte-aligned BitArrays and concrete nominal
values structurally, including nested strings, Result, generic fields, and regular
recursive or mutually recursive types. Comparison plans use the merged operand
type, so empty lists and unused Result alternatives infer from the other operand.
Unresolved fields in unreachable variants use a trap helper, never a guessed word
layout. Phantom type parameters need no stored-field comparator.

`native/equality` registers a type before descending into its fields, allowing
recursive references. A 128-node bound explicitly rejects non-regular expanding
recursion and excessively large shape graphs. Stored erased type parameters and
function-value equality remain unsupported. Equality allocates no heap memory;
list tails loop, while nested fields and recursive trees still consume call stack.

Value/module-name collisions follow upstream field priority: an existing local
record field wins; otherwise the imported module member is resolved with normal
visibility checks. A present non-callable field is an error when called, rather
than a reason to fall back to a module function. Closure captures and guards retain
local-field semantics.

## Limits that must not be confused with full Gleam compatibility

* Only Linux x86-64 executable output is implemented. No ARM64/Mach-O target yet.
* Selective/unqualified imports, package resolution, labelled function calls,
  general type inference, constants and attributes are not implemented. These limit
  upstream compatibility; the current compiler API sources fit the supported subset.
* Named polymorphic functions can be called directly, but cannot yet be taken as
  polymorphic first-class values. Local function parameters/returned functions
  have their checked function types; there is no general let-polymorphism or
  omitted-signature inference. Generic equality/printing remain rejected where
  the current erased representation cannot provide their semantics.
* Opaque types and empty custom types are not implemented.
  Shadowing built-in Int/Bool/Nil/String/List types or True/False/Nil constructors
  is explicitly rejected for now. User-defined Result/Ok/Error names
  are supported. Private-type checking covers public function signatures and
  public constructor fields after project resolution. Builtin shadowing is valid
  upstream but remains an explicit unsupported subset feature here, including in
  imported modules.
* Decimal literal magnitudes now extend through 9,007,199,254,740,991 (2^53-1),
  with unary negation supported. Digit accumulation checks before arithmetic and
  groups the digit subtraction to avoid intermediate bootstrap rounding. Larger
  literals are rejected explicitly until an independent exact representation is
  implemented. Generated arithmetic remains checked signed 64-bit; overflow exits
  70. This is not Gleam's complete cross-target integer semantics.
* Strings retain valid scalar UTF-8 bytes; only a few source escapes are supported.
  Unicode escape syntax and grapheme operations remain unsupported.
  General pattern aliases are supported as described below. String prefixes/concatenation/equality are byte-based and do not
  normalize equivalent Unicode spellings.
* Compound objects and function descriptors use a single 64 MiB read/write, non-executable mmap arena, only in
  programs with compound allocation. Allocation is checked and exhaustion exits
  71. There is no collection or arena growth yet. This is not the final memory
  manager. Compound printing remains unsupported; structural equality is described below.
* Single-subject cases retain the legacy coverage fast path and diagnostics,
  with the existing constructor-product matrix as a fallback. Split nested ADT,
  tuple and list coverage can now prove exhaustiveness across arms; guards never
  contribute. Infinite domains and bit-array coverage remain conservative.
  Refutable lets remain rejected until let-assert is supported. Direct/simple
  local known-constructor values narrow that constructor set; nested values and
  arbitrary function calls do not acquire invented refinement facts.
* `echo` prints a value and newline to stdout without upstream's source-location
  diagnostics. That is a seed diagnostic convention, not completed `echo`
  compatibility. Oracle tests compare returned pure values and render them
  separately; they do not assert identical upstream debug formatting.
* Ordinary language `echo` helpers still issue a single write syscall. The native
  CLI's file and diagnostic IO has separate complete-write/EINTR loops; that does
  not silently change ordinary program echo behavior.
* There is no optimizer, garbage collector, package manager, formatter or language
  server in this rewrite. The upstream compiler remains untouched.

## Evidence and next work

`test/oracle.gleam` is compiled by the unmodified upstream compiler. Its actual
JavaScript results are compared with execution of independently generated native
programs, including recursion, signed division/remainder, booleans, cases, strings
and lexical scope. Other tests cover side effects/short-circuiting, argument
order, fixed-width overflow, deterministic ELF output, absent interpreter/dynamic
segments, stack permissions, invalid programs and the empty dependency list.

The first seed run passed 43/43 checks and is preserved in
`evidence/seed-verification.json`. The collections milestone passes 66/66,
including upstream oracle comparisons and actual exact-fit/over-end arena probes.
These are subset checks, not upstream compiler conformance.
`evidence/collections-verification.json` contains that milestone's source/artifact hashes,
measured example sizes, a native disassembly reference and explicit bootstrap
state. [ASM.md](ASM.md) documents the emitted calling convention, registers,
object layout and guarded failure paths.

The custom-type milestone passes **105/105** checks plus **8/8** fresh upstream
accept/reject comparisons, including constructor callability, known variants,
private type visibility and wrong field types. Its historical source/artifact hashes
and native examples are in `evidence/custom-types-verification.json`; the earlier
seed/collections receipts remain historical. Inspect
`evidence/custom_types-disassembly.txt` for actual null/tag checks before field
loads. No compiler speed or output-speed claim follows from those checks.

The generic-types/records milestone passes **146/146** checks plus **15/15** fresh
upstream accept/reject comparisons. Accepted cases also execute through the
upstream toolchain to compare numeric/Bool/Nil output, including observable
labelled-argument evaluation order. `evidence/generics-records-verification.json`
contains that milestone's source/artifact hashes and `evidence/generics_records-disassembly.txt`
contains actual field-access instructions. The four older native examples retain
their exact previous hashes. A paired test also verifies identical machine code
for Box(Int) holding 1 and Box(Bool) holding True; this demonstrates representation
erasure for that case, not a performance benchmark or a general compatibility proof.

The functions milestone passes **170/170** checks plus **22/22** upstream
accept/reject comparisons. It covers generic recursion, rigid type variables,
higher-order calls, lexical shadowing, returned pointers, callback records and
indirect evaluation order/stack cleanup. Accepted comparison cases execute their
main entry; the mutually recursive nonterminating functions in one acceptance
fixture are deliberately not invoked. Historical hashes and native disassembly are
in `evidence/functions-verification.json` and `evidence/functions-disassembly.txt`.
At that milestone all five older examples retained their previous hashes.

The closures/`use` milestone passes **210/210** checks plus **31/31** fresh
upstream accept/reject comparisons. Tests cover returned/nested captures, shadowing,
generic closures, callback records, contextual typing, parameter patterns,
callback invocation order and rejected unsafe inference. Actual capture loads and
indirect-call instructions are retained in `evidence/closures-disassembly.txt`.
`evidence/closures-verification.json` records the exact source hashes and bootstrap
state. The 1,021-byte closure example prints `12,22,6`; this is a program size,
not compiler size or a speed measurement. The first five older examples remain
byte-identical. The named-function example grows from 867 to 1,050 bytes because
of the intentional descriptor ABI change; its old receipt/disassembly are
preserved, and the current listing is `evidence/functions-descriptor-disassembly.txt`.
See [SELF_HOSTING.md](SELF_HOSTING.md) for the remaining bootstrap criteria.

The record-update milestone passes **230/230** checks and **42/42** fresh upstream
comparisons. This includes generic type changes, retained-field constraints,
phantom parameters, nested updates, captured records, callback context, unsafe
variants, immutable originals and observable evaluation order. Its receipt is
`evidence/record-updates-verification.json`; its native listing is
`evidence/record_updates-disassembly.txt`. The 930-byte example prints `3,7,True`.
All seven prior example binaries remain byte-identical. Larger input testing also
exposed bootstrap recursion in relocation emission; the pass now accumulates
chunks iteratively, with a 12,000-instruction relocation regression test. This
changes host traversal, not emitted bytes. [JOURNEY.md](JOURNEY.md) records findings.

The byte-aligned bit-array milestone passes **293/293** checks and **64/64**
upstream comparisons. Tests independently check actual bytes and signed extraction
at every supported width and byte order, as well as immutable concatenation,
returned/captured slices, option rules, length guards and bounded-arena exhaustion.
The initial zero-width evaluation mismatch is preserved in
`evidence/bit-arrays-zero-width-failure.txt`, and the correction is described in
[JOURNEY.md](JOURNEY.md). Current source/artifact hashes are in
`evidence/bit-arrays-verification.json`; the 1,825-byte example prints `5,9,-2,4660`.
All eight prior examples retain their exact hashes. This measures example size,
not compiler size or speed.

The local-module milestone passes **336/336** checks and **97/97** fresh upstream
comparisons: 64 existing single-file comparisons plus 33 multi-module fixtures.
They cover alias shadowing, private helpers/access denial, generic types/calls,
qualified record updates/patterns, shared imports, recursion, cross-module nominal
mismatches and cycles. `evidence/modules-verification.json` records source and
bootstrap-bridge hashes plus the resolved example symbol names. The 1,060-byte
module example prints `14,8,3`, with its actual direct-call instructions retained
in `evidence/modules-disassembly.txt`. All nine older examples remain byte-identical.
Builtin-shadowing rejection is tested separately as a known subset restriction,
not counted as an upstream agreement. Its initial comparison is preserved in
`evidence/modules-builtin-shadow-limit.txt`.

The aliases/guards milestone passes **382/382** checks and **141/141** fresh
upstream comparisons (64 existing single-file and 77 project fixtures). Evidence
includes defining-module alias scope, generic function aliases, recursive nominal
boundaries, private alias/type distinctions, guard-only captures, fallthrough and
rejected side effects/coverage claims. A full-byte test shows generic tuple aliases
produce exactly the same executable as underlying tuple annotations. The receipt
is `evidence/aliases-guards-verification.json`; the 1,269-byte example prints
`7,5,True,False` and its actual branches/capture loads are in
`evidence/aliases_guards-disassembly.txt`. All ten prior example hashes are unchanged.

The strings/prelude milestone passes **437/437** checks and **173/173** fresh
upstream comparisons. Additional pure string oracles compare actual upstream
return values with native printing, including Unicode and embedded newlines.
Malformed UTF-8 validation is compared against an independent fatal decoder on
boundaries, every single byte and 1,000 deterministic samples. The compiler's own
`native/utf8` module also compiles and runs natively on valid/invalid byte sequences;
this is an owned-component test, not full compiler self-hosting.

`evidence/strings-prelude-verification.json` records current source hashes and
`evidence/strings_prelude-disassembly.txt` retains actual comparison/copy instructions.
The 1,852-byte example prints two True values, `λ😀`, then UTF-8 bytes `206,187`.
All eleven earlier example binaries remain byte-identical. Repeated string growth
also verifies guarded arena exhaustion before copying; reclamation remains open.

The multi-subject/alternative milestone passes **479/479** checks and **213/213**
fresh upstream comparisons (64 single-file plus 149 project fixtures). Tests cover
guard retry with different binding values, consistent name/type sets, shared bodies,
returned closures, correlated coverage holes and subject evaluation order.
`evidence/multi-patterns-verification.json` records source/artifact hashes;
`evidence/multi_patterns-disassembly.txt` records actual retry branches. The
1,146-byte example prints `7,9,3` without a heap initializer. All twelve earlier
example binaries remain byte-identical.

The actual `src/native/core.gleam` module also compiles natively, with all its
functions included. `test/owned-core-driver.source` exercises lists, decimal
strings, prefix classification, lookup, byte construction, map/nth/put and errors.
Native results are compared with actual upstream-compiled core function results.
`evidence/owned-core-native-verification.json` records source/driver hashes and the
12,064-byte executable's output/hash. That size includes core plus its test driver;
it is not the size of the complete compiler, nor a full self-hosting result.

The structural-equality milestone passes **516/516** checks and **246/246** fresh
upstream comparisons (64 single-file plus 182 project fixtures). The 2,602-byte
example prints `True,False,True,True`; all thirteen earlier executable hashes are
unchanged. Source hashes, outputs, limits and actual instructions are retained in
`evidence/structural-equality-verification.json` and
`evidence/structural_equality-disassembly.txt`.

The complete actual type-system module now compiles and executes natively with
core/AST dependencies (24,916 bytes including its driver). The actual equality
planner also runs natively with its definition collector and dependencies (48,175
bytes including its driver), producing the expected recursive three-node plan.
Their separate `owned-*-native-verification.json` receipts compare outputs against
upstream-compiled owned modules. Neither size is the complete compiler size.
The historical complete compiler API probe stopped at a nested `as` pattern; see
`evidence/complete-api-equality-probe.json`. That syntax is now supported. The
historical next probe reached an integer-literal limit in the assembler; see
`evidence/complete-api-pattern-aliases-probe.json`. Both barriers are now cleared;
the current native API proof is described below. A stage-2 rebuild is not claimed.

The pattern-alias milestone passes **546/546** checks and **276/276** fresh
upstream comparisons (64 single-file plus 212 project fixtures). Its 884-byte
example prints `14,10`, with no alias allocation/copy in the inspected ASM. All
fourteen earlier example hashes remain unchanged, and the owned compiler-component
native checks still pass. Source/artifact hashes and fresh oracle diagnostics are
in `evidence/pattern-aliases-verification.json` and its linked receipts.

The integers/coverage/native-API milestone passes **572/572** tests and
**297/297** fresh upstream comparisons (64 single-file plus 233 project fixtures).
The 662-byte wide-pattern example prints `True,False,9007199254740991,-2147483648`;
all fifteen earlier example hashes are unchanged. The owned core/type-system/
equality-planner checks pass again with current source hashes.
`evidence/integers-coverage-verification.json` links the fresh checks and actual ASM.

The complete compiler API plus its bounded driver is **498,418 bytes**. It runs
without a dynamic loader or shared libraries and natively emits 380- and 745-byte
programs, both exactly identical to bootstrap output; both execute correctly.
`evidence/complete-api-wide-integers-probe.json` records source/driver/image hashes,
ELF headers and child execution. This measures a native compiler core plus driver,
not a finished file-based CLI, full Gleam compatibility or a self-rebuild.

The earlier bounded native CLI milestone passed **631/631** tests and **297/297** fresh upstream
comparisons. Its **59** CLI-specific tests compile/execute all sixteen examples
with an empty PATH, preserve existing outputs, test input bounds and exercise IO
failure paths. All sixteen earlier example hashes remain unchanged. The standalone
CLI is **582,442 bytes**, with no dynamic loader/segment and an RW non-executable
stack. Source/test/bridge hashes and real observations are linked from
`evidence/native-cli-verification.json`.

The ptrace harness shortened real kernel requests to seven bytes: the observed
run had **4 positive short reads and 54 positive short writes**, emitted the exact
expected executable, and spawned no further program. Separate strace injections
verify EINTR retries, close-error handling and temporary cleanup. These are
explicit development-only tests, not libraries or wrappers inside the native CLI.

Next actions after self-hosting:

1. Measure emitted frame/temporary traffic; implement bounded look-ahead and
   register retention/spilling with explicit call/syscall clobber contracts.
2. Expand compatibility and exact value semantics using independent upstream
   comparisons and actual native-path regressions.
3. Address further measured allocation or non-tail stack limits without changing
   language semantics or introducing external dependencies.
4. Add additional targets and distribution with actual target qualification.

No time, final compiler size, compile-speed or language-wide runtime-performance
claim is established by the native seed. The finished compiler's external
dependency budget remains zero.

## First self-hosting qualification — 2026-11-08

The first milestone result is preserved separately in
[evidence/self-hosting-qualification.json](evidence/self-hosting-qualification.json):
657 regression checks, 317 fresh upstream comparisons, 59 targeted native CLI
checks, and the entire 317-case corpus compiled by the rebuilt stage-3 compiler.
The native corpus contains 198 accepted and 119 rejected cases. Every accepted
image matches bootstrap bytes and executes with the expected output. Historical
milestone counts and artifacts above remain records of their original source.

The former 33,036-byte stack failure is reproduced and attributed to actual UTF-8
validator frames. Direct self-tail lowering removes that stack growth; a million
iterations also finish under a 64 KiB stack. Heap failures before the copying fixes
and successful full compiler rebuild consumption are preserved in
[evidence/self-hosting-scale-frontier.json](evidence/self-hosting-scale-frontier.json).
No installed Crew/compiler executable or active session was replaced.

## Look-ahead and conservative register retention — 2026-11-08

The leaf-register qualification passed **677 tests and 333 fresh upstream comparisons**.
The rebuilt stage-3 compiler qualifies all 333 cases (213 accepted, 120 rejected).
Both native self-rebuilds remain byte-identical to their seed; that image
is 596,782 bytes. See [qualification](evidence/leaf-register-qualification.json)
and [rebuilds](evidence/leaf-register-native-rebuilds.json).

A leaf right operand lets the emitter retain left in RCX instead of spilling it.
Right operands with calls or other clobbers retain their existing push/pop path.
The fixed-source comparison removes 260 static push/pop pairs and 451 instructions;
frame-slot traffic is unchanged. The same target source image shrinks 334 bytes.
This is not a whole-function register allocator or a measured runtime speedup.
The new compiler itself includes the optimization and lexical correction, so its
source/image growth is distinct from that fixed-source saving.

An independent comparison caught an older signed-number parsing mismatch after
calls and whitespace. That input and failure are retained; token-end tracking now
matches the new upstream cases. See [design and limits](REGISTER_SPILL_SPEC.md).
The verifier defaults to current-* development receipts; GIG_VERIFY_PREFIX selects
a separate milestone prefix so earlier evidence remains intact.

## Sibling-arm local-slot reuse — 2026-11-08

Case siblings now share local slots, reserving the maximum arm footprint while
preserving outer variables, saved subjects and independent closure helper frames.
On identical compiler source, 95 of 384 named function frames shrink: aggregate
reserved bytes fall 36,800 → 26,112 (about 29%). This is a static sum, not dynamic
peak stack/RSS. The lexer frame falls 880 → 208 bytes; the parser pattern routine
944 → 192 bytes. Fixed-source executable length is unchanged.

A controlled 64 KiB stack workload fails with the earlier 208-byte frame and
succeeds with the new 32-byte frame. This is non-tail recursion with input 600,
terminal arm 7 and exact result 180285, not arbitrary-input or timing evidence.
[Both observations](evidence/branch-slots-small-stack.json) are retained.

Sibling-slot qualification: **687 tests, 341 fresh upstream comparisons**, and all 341
cases through the rebuilt compiler. Two native self-rebuilds again match their
seed. That compiler was 597,813 bytes; no new runtime dependency.
See [qualification](evidence/branch-slots-qualification.json),
[fixed-source frames](evidence/branch-slots-frame-comparison.json) and
[design/remaining allocator work](REGISTER_SPILL_SPEC.md).

## Typed integer-region allocation — 2026-11-08

Call-free checked integer expressions now use an owned typed instruction plan.
Explicit uses/definitions include condition flags; backward liveness removes dead
moves while retaining arithmetic traps. The allocator uses RAX/RCX/RDX and spills
to the machine stack when the region exceeds that pool, with RDI reserved for
recovery. Left-to-right evaluation and immediate overflow checks remain intact.
That first increment retained legacy calls/effects/control flow. It established expression-
region allocation, not whole-function control-flow liveness.

The first typed-region qualification passed **702 tests and 351 fresh upstream comparisons**. The rebuilt
native compiler qualifies all 351 corpus cases, and both native self-rebuilds are
byte-identical. A separate seeded 100-expression program agrees with independent
BigInt results and upstream: 68 regions spill, maximum operand pressure seven,
and native bytes match bootstrap. These 100 expressions are not counted as 100
additional compilation cases in the 351-case corpus.

The fixed compiler-source comparison removes 15 push/pop pairs, 54 static named-
function instructions and 116 image bytes. The current compiler itself is
613,842 bytes because it includes the new planner implementation.
No runtime speed or whole-function allocation claim follows from these results.
See [qualification](evidence/integer-regions-qualification.json),
[seeded oracle](evidence/integer-regions-seeded-oracle.json),
[static comparison](evidence/integer-regions-comparison.json) and
[design](REGISTER_SPILL_SPEC.md).

## Caller-save allocation for named integer calls — 2026-11-08

Typed regions now admit named functions returning Int with supported integer
arguments. The call mask kills every allocatable register, recovery scratch and
flags. Live ancestor operands are pushed before evaluating arguments, which run
left-to-right with a fresh register pool. Each argument is staged on the existing
stack ABI. After the call and argument cleanup, copy the RAX result to its assigned
register before restoring saved operands in reverse order. Calls remain effectful
and cannot be deleted when their result is dead.

The named-call qualification passed **715 tests and 361 fresh upstream comparisons**. The rebuilt
compiler qualifies all 361 corpus cases and both native self-rebuilds match the
seed. A separate 100-expression call oracle exercises 286 named calls and verifies
386 ordered output effects against BigInt modeling and upstream. The earlier pure
100-expression program still produces exactly its previous image. These are two
stress programs, not 200 additional independent compilation cases in the corpus.

The frozen compiler-source image and static instruction counts are unchanged.
This is a tested allocation foundation across calls, not a speedup claim; result
placement/coalescing may need further work. The current compiler includes the new
implementation and is 617,676 bytes. Indirect calls, non-integer arguments,
effects outside callees and general control-flow joins retain legacy lowering.
See [qualification](evidence/named-calls-qualification.json),
[call/effect oracle](evidence/named-calls-seeded-effects.json),
[static comparison](evidence/named-calls-comparison.json) and
[design](REGISTER_SPILL_SPEC.md).

## Scalar control-flow joins and measured performance — 2026-11-08

The typed plan now includes real labels, conditional/unconditional jumps, scalar
comparisons, short-circuit Boolean expressions and supported two-arm scalar cases.
Successor-aware liveness preserves definitions needed by either branch and reaches
a fixed point on backedges. Each selected path returns RAX; joins copy that result
before restoring outer operands. Guarded/data-binding/general matches retain
legacy lowering. This is not whole-function allocation for every construct.

Qualification: **729 tests, 371 fresh upstream comparisons**, all 371 cases through
the rebuilt compiler and two byte-identical native self-rebuilds. Three separate
100-expression oracles cover pure arithmetic, calls/effects and nested branches.
An initial verification timeout is preserved; straight-line regions now use the
previous linear scan, and the aggregate multi-stage proof has an appropriate
180-second allowance while individual native limits remain unchanged.

The new compiler is 637,999 bytes, without external runtime dependencies.
Its current-source self-build measured **8.75 s median wall / 7.42 s CPU** and
**390.8 MiB maximum RSS** on this shared pinned-core host. No broad speedup is
established: branch code is 45 bytes smaller with about 2% less CPU time here,
while short-circuit code uses about 3% more CPU. Identical-code controls show noisy
wall-time differences. See [full method/results](BENCHMARKS.md),
[qualification](evidence/control-flow-qualification.json) and
[actual self-build samples](evidence/control-flow-self-build-benchmarks.json).


## Allocation reduction — 2026-11-08

A phase trace found millions of temporary byte-tail descriptors in pure counting
loops. Structural recognition now replaces exactly that effect-free loop with a
length load and checked addition; it never chooses an optimization by function name.
On identical frozen compiler input, allocated volume falls **17.2%** and peak RSS
falls **390.8 → 323.6 MiB**, without GC. At that milestone the compiler was 644,591 bytes;
744 tests, 383 upstream comparisons and two byte-identical native rebuilds passed.
See [MEMORY.md](MEMORY.md) for measurements, emitted instructions and remaining work.


## Direct lookup and retained parsed sources — 2026-11-08

Project resolution now searches immutable lists without rebuilding temporary name
maps. CLI loading retains each parsed module alongside its original read snapshot;
linking reuses that AST. Raw source callers remain supported and unreachable raw
sources remain unparsed. No persistent mutable cache or runtime dependency was added.

On the same frozen input as the previous experiment, resolution allocation falls
60.4 → 10.7 MB, and duplicate lex/parse work is eliminated. Total rebuild allocation
falls 338.7 → 228.9 MB; peak RSS falls 323.6 → 218.5 MiB. Compared with the original
pre-byte-count baseline, allocation is down 44.0%. The native image is 645,969 bytes.
All 748 tests and 383 upstream comparisons pass; native rebuilds are byte-identical.
See [MEMORY.md](MEMORY.md), [the full guide](GUIDE.md) and the separately retained
[qualification](evidence/parsed-snapshot-qualification.json).
