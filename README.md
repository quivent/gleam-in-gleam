# Gleam in Gleam

A compiler rewrite in Gleam, with direct machine-code generation and **zero
third-party dependencies** as a hard design constraint. No LLVM, Cranelift,
Glance, standard-library package, external assembler, external linker, libc,
or bundled VM is used by the native seed.

**Status: working native language seed, not a complete Gleam compiler and not
self-hosted yet.** The compiler currently runs through a clearly separated
JavaScript bootstrap. Generated programs are native Linux x86-64 ELF executables.
The intended finished compiler must itself be a standalone native executable.

## What actually runs

Current bootstrap:

```text
Gleam compiler source (this repository)
    → existing Gleam 1.19.2 bootstrap compiler
    → generated JavaScript + Node host-IO bridge
    → input Gleam source
    → native ELF bytes
    → Linux kernel executes the program
```

The final two steps do not use Node, Rust, Gleam tooling, libraries, a dynamic
loader, an assembler or a linker. The compiler currently does require the
bootstrap. A 601-byte Fibonacci executable is **a generated example program**,
not the size of a completed compiler.

Target bootstrap completion:

```text
Stage 0: existing toolchain compiles the compiler's Gleam source once
Stage 1: that compiler emits a native compiler from the same source
Stage 2: the native compiler recompiles itself with identical output
```

Stage 1 and Stage 2 have not been achieved. Self-hosting is only established
after that chain succeeds; accepting the compiler's text or wrapping its
JavaScript in a native executable would not establish it.

## Run the current implementation

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

## Current implementation

All parsing, checking, instruction selection, relocation and ELF writing live in
Gleam. `bootstrap.mjs` supplies argument/file IO and converts the bootstrap's
BitArray representation. It performs no language compilation itself.

| Module | Responsibility |
| --- | --- |
| `native/core` | Compiler-owned list, byte and diagnostic utilities |
| `native/lexer` | Tokens, comments, decimal literals, UTF-8 string bytes |
| `native/ast` | Language seed syntax types |
| `native/parser` | Precedence, functions, bindings, calls and case expressions |
| `native/check` | Typed expressions, constructor inference, scope and exhaustiveness |
| `native/definitions` | Nominal types, constructor identities and public interfaces |
| `native/type_system` | Scoped constructor/function substitution and function types |
| `native/free_names` | Lexically scoped free names for copied closure captures |
| `native/bit_options` | Static byte-segment options and pattern/construction validation |
| `native/labels` | Constructor labels, positional validation and declaration ordering |
| `native/x64` | Direct instruction selection, stack frames and syscall helpers |
| `native/heap` | Bounded arena allocation through direct Linux mmap |
| `native/assembler` | Internal labels and signed relative relocations |
| `native/elf` | ELF64 image and program headers, non-executable stack |
| `native/compiler` | Compile pipeline |

The internal assembler is written in Gleam and emits bytes. It is not an
external assembler dependency. The small generated integer/string print
helpers are part of the generated program's code, not a separately installed
runtime. Automatic memory management for future allocated values will also
need compiler-owned code; zero external dependencies does not mean that memory
management can be omitted.

Implemented seed features: explicitly typed functions and parameters,
forward/recursive calls, local bindings and shadowing, Int/Bool/Nil/static
String values, integer operations, comparisons, short-circuit booleans,
single-subject case matching, exhaustiveness checks for this subset and primitive
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
UTF-8 segments and structural BitArray equality/printing remain unsupported.

## Limits that must not be confused with full Gleam compatibility

* Only Linux x86-64 executable output is implemented. No ARM64/Mach-O target yet.
* Imports, labelled function calls, general type inference, constants,
  attributes are not implemented. The compiler uses several of those itself, so cannot self-compile.
* Named polymorphic functions can be called directly, but cannot yet be taken as
  polymorphic first-class values. Local function parameters/returned functions
  have their checked function types; there is no general let-polymorphism or
  omitted-signature inference. Generic equality/printing remain rejected where
  the current erased representation cannot provide their semantics.
* Opaque types and empty custom types are not implemented.
  Shadowing built-in Int/Bool/Nil/String/List types or True/False/Nil constructors
  is explicitly rejected for now. User-defined Result/Ok/Error names
  are supported. Private-type checking covers public function signatures and
  public constructor fields within the current single-module implementation.
* Integer literals are restricted to nonnegative decimal magnitudes up to
  2,147,483,647 (with unary negation supported). Generated arithmetic is checked
  signed 64-bit arithmetic; overflow exits 70. This is an explicit seed
  limitation, not Gleam's full cross-target integer semantics.
* String literals retain their UTF-8 bytes; only a few escapes are supported.
  String structural equality and dynamic string allocation are not implemented.
* Compound objects and function descriptors use a single 64 MiB read/write, non-executable mmap arena, only in
  programs with compound allocation. Allocation is checked and exhaustion exits
  71. There is no collection or arena growth yet. This is not the final memory
  manager. Structural compound equality/printing remain rejected.
* Case coverage is conservative. Empty/nonempty lists with irrefutable head/tail,
  fully irrefutable tuples, Bool alternatives and catch-alls are understood;
  more complex coverage may require an explicit catch-all. Refutable lets are
  rejected until let-assert is supported. A custom-type case must cover every
  possible constructor with irrefutable fields, or use a catch-all. Direct/simple
  local known-constructor values can narrow that constructor set, as upstream
  does; this knowledge is not propagated into nested fields or across function
  calls. Other valid refinement/coverage combinations may still be rejected.
* `echo` prints a value and newline to stdout without upstream's source-location
  diagnostics. That is a seed diagnostic convention, not completed `echo`
  compatibility. Oracle tests compare returned pure values and render them
  separately; they do not assert identical upstream debug formatting.
* The generated print helpers currently issue a single write syscall. General
  partial-write/EINTR handling and file IO belong to the upcoming native runtime.
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

Next actions, in dependency order:

1. Add module imports and the remaining bit-array operations, testing each
   against upstream results and failures. Structural
   equality and owned collection also remain necessary work.
2. Supply native file/argument/syscall IO in the owned runtime; remove the Node
   bootstrap bridge from the native compiler execution path.
3. Compile the compiler source natively, then rebuild that compiler with itself
   and compare exact bytes. Record actual size and dependencies at each stage.
4. Expand upstream compatibility and add a direct ARM64/Mach-O emitter. Verify
   architecture/OS semantics rather than assuming ELF code transfers unchanged.

No time, final compiler size, compile-speed or language-wide runtime-performance
claim is established by the native seed. The finished compiler's external
dependency budget remains zero.
