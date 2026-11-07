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
| `native/x64` | Direct instruction selection, stack frames and syscall helpers |
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
single-subject case matching, exhaustiveness checks for this subset and value
printing. Calls preserve left-to-right evaluation order. Division/remainder by
zero return zero. Unsupported constructs produce diagnostics rather than
delegating compilation elsewhere.

## Limits that must not be confused with full Gleam compatibility

* Only Linux x86-64 executable output is implemented. No ARM64/Mach-O target yet.
* Imports, custom types, tuples, lists, closures, generics, `use`, labelled
  arguments, type inference, constants, attributes and bit-array syntax are not
  implemented. The compiler uses several of those itself, so cannot self-compile.
* Integer literals are restricted to nonnegative decimal magnitudes up to
  2,147,483,647 (with unary negation supported). Generated arithmetic is checked
  signed 64-bit arithmetic; overflow exits 70. This is an explicit seed
  limitation, not Gleam's full cross-target integer semantics.
* String literals retain their UTF-8 bytes; only a few escapes are supported.
  String structural equality and dynamic string allocation are not implemented.
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

The first run passed 43/43 checks. These are seed checks, not upstream compiler
conformance. `evidence/seed-verification.json` contains source/artifact hashes,
measured example sizes and explicit bootstrap state.

Next actions, in dependency order:

1. Add typed tuples/lists/custom types and their pattern matching, with owned
   allocation/collection and structural equality.
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
