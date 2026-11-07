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
| `native/check` | Monomorphic checking, signatures, scope and exhaustiveness |
| `native/definitions` | Nominal types, constructor identities and public interfaces |
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
value printing. Typed tuples, tuple indexing/destructuring, monomorphic lists,
list spreads and nested tuple/list patterns are supported. Calls and compound
fields preserve left-to-right evaluation order. Division/remainder by
zero return zero. Unsupported constructs produce diagnostics rather than
delegating compilation elsewhere.

Monomorphic custom types now support positional constructors, zero-field values,
recursive/mutually recursive definitions and nested constructor matching inside
lists/tuples. Constructor fields are checked against their declared nominal
types, not just their memory shape. Public interfaces cannot expose private
types. A zero-field constructor is a value rather than a callable function.
Known top-level constructor identity is retained across simple local bindings,
including annotations, for let-pattern/case checking. Runtime tag checks remain
in the emitted code; this is semantic checking, not a tag-check optimization.

## Limits that must not be confused with full Gleam compatibility

* Only Linux x86-64 executable output is implemented. No ARM64/Mach-O target yet.
* Imports, closures, generics, `use`, labelled
  arguments, type inference, constants, attributes and bit-array syntax are not
  implemented. The compiler uses several of those itself, so cannot self-compile.
* Custom types are monomorphic and positional. Generic/opaque types, labelled
  fields/calls, record access/updates and empty custom types are not implemented.
  Shadowing built-in Int/Bool/Nil/String/List types or True/False/Nil constructors
  is explicitly rejected for now. Monomorphic user-defined Result/Ok/Error names
  are supported. Private-type checking covers public function signatures and
  public constructor fields within the current single-module implementation.
* Integer literals are restricted to nonnegative decimal magnitudes up to
  2,147,483,647 (with unary negation supported). Generated arithmetic is checked
  signed 64-bit arithmetic; overflow exits 70. This is an explicit seed
  limitation, not Gleam's full cross-target integer semantics.
* String literals retain their UTF-8 bytes; only a few escapes are supported.
  String structural equality and dynamic string allocation are not implemented.
* Tuples/lists use a single 64 MiB read/write, non-executable mmap arena, only in
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
private type visibility and wrong field types. Its current source/artifact hashes
and native examples are in `evidence/custom-types-verification.json`; the earlier
seed/collections receipts remain historical. Inspect
`evidence/custom_types-disassembly.txt` for actual null/tag checks before field
loads. No compiler speed or output-speed claim follows from those checks.

Next actions, in dependency order:

1. Extend custom-type support with generic types and labelled fields/access.
   Monomorphic constructors, recursive types and nested matching are implemented.
   Structural equality and owned collection remain necessary follow-up work.
2. Add polymorphic inference, closures/first-class functions, `use`, byte arrays
   and module imports, testing each against upstream results and failures.
3. Supply native file/argument/syscall IO in the owned runtime; remove the Node
   bootstrap bridge from the native compiler execution path.
4. Compile the compiler source natively, then rebuild that compiler with itself
   and compare exact bytes. Record actual size and dependencies at each stage.
5. Expand upstream compatibility and add a direct ARM64/Mach-O emitter. Verify
   architecture/OS semantics rather than assuming ELF code transfers unchanged.

No time, final compiler size, compile-speed or language-wide runtime-performance
claim is established by the native seed. The finished compiler's external
dependency budget remains zero.
