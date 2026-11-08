# Gleam in Gleam: implementation and user guide

This project rewrites a supported subset of Gleam in Gleam and emits standalone
Linux x86-64 executables directly. It is not a new language, a complete upstream
Gleam implementation, or a wrapper that delegates compilation to another compiler.
The acceptance boundary is the qualified syntax/semantics described here and in
the tracked tests. Unsupported constructs must fail explicitly.

The compiler owns lexing, parsing, module resolution, checking, instruction
selection, relocation, ELF generation, allocation and runtime IO. Delivered native
images require no standard-library package, LLVM, Cranelift, external assembler,
external linker, libc, JavaScript VM or downloaded runtime. Development tools are
separate: an existing Gleam compiler and Node bootstrap the first native image;
Python, objdump, strace and ptrace verify and measure it.

## 1. Building and using it

### Bootstrap once

Development prerequisites are upstream Gleam 1.19.2, Node 22+, and Linux x86-64
for executing native artifacts. The package manifests have no third-party packages.
Run these commands from the repository root, choosing destinations that do not
already exist:

```sh
gleam build --warnings-as-errors
mkdir -p out
node build-native.mjs out/my-gleam-native
./out/my-gleam-native --version
./out/my-gleam-native --help
```

`build-native.mjs` supplies host IO to the Gleam implementation and writes its
result. It does not implement parsing, checking or instruction selection. The
resulting executable uses direct Linux syscalls, including rooted source access
and exclusive output publication; it does not run Node or upstream Gleam.

### Compile an application

Native command syntax:

```text
gleam-native SOURCE.gleam NEW_OUTPUT [--source-root DIRECTORY]
gleam-native --build-compiler NEW_OUTPUT [--source-root DIRECTORY]
```

For a single source file, put the following in `demo/main.gleam`:

```gleam
fn twice(n: Int) -> Int {
  n * 2
}

pub fn main() -> Nil {
  echo twice(21)
  Nil
}
```

Then run:

```sh
./out/my-gleam-native main.gleam out/my-demo --source-root demo
./out/my-demo
# 42
```

SOURCE is relative to the source root, which defaults to the current directory.
The default differs from `bootstrap.mjs`, whose source root defaults to the input
file's directory. Native sources must be relative module paths, ending in `.gleam`.
The entry module must supply its own `main`; importing another module's `main`
does not provide one.

All output paths must be new. The compiler refuses to replace existing files,
directories or symlinks. It uses an exclusive sibling output, complete writes,
fsync and no-replace rename. A failed compile must not publish a partial result.
Keep intentional old outputs, or explicitly remove only your own disposable output.

### Rebuild the compiler with itself

```sh
./out/my-gleam-native --build-compiler out/my-stage2 --source-root src
./out/my-stage2 --build-compiler out/my-stage3 --source-root src
cmp out/my-gleam-native out/my-stage2
cmp out/my-stage2 out/my-stage3
```

Do not change source between those steps. A qualified self-hosting result means
these native stages actually read the frozen compiler sources and emit identical
images. A changed-source control also checks that this is compilation rather than
copying the running executable. It does not imply full upstream compatibility.
See [SELF_HOSTING.md](SELF_HOSTING.md) for the latest exact artifacts and tests.

## 2. Language syntax and semantics

### Declarations, values and functions

Top-level functions declare parameter and return types. `pub` exports a declaration;
ordinary `fn` remains private to its module. Forward and recursive calls work.
Function bodies and blocks return their final expression. `Nil` is the unit value.
Bindings use `let`; shadowing creates a new immutable binding rather than mutation.

```gleam
fn sum(n: Int, acc: Int) -> Int {
  case n {
    0 -> acc
    _ -> sum(n - 1, acc + n)
  }
}

pub fn main() -> Nil {
  let answer: Int = sum(10, 0)
  let answer = answer + 1
  echo answer
  Nil
}
```

Source primitive types are `Int`, `Bool`, `Nil`, `String` and `BitArray`. Composite
types include `List(a)`, tuples such as `#(Int, String)`, function types such as
`fn(Int) -> Bool`, and nominal/generic custom types. Type variables are scoped;
this is not general Hindley–Milner inference for arbitrary unannotated programs.

Integer operations include checked native arithmetic, comparisons and remainder.
Native Int is signed 64-bit, but source integer literal magnitudes are presently
limited to the bootstrap-exact 2^53−1 range. Do not assume arbitrary-precision
arithmetic or silently rounded literals. Overflow traps exit 70. Division and
remainder by zero produce zero under the implemented Gleam semantics.
`&&` and `||` short-circuit; effects in the unused operand do not execute.

Binary precedence, from weakest to strongest, is `||`, `&&`, equality,
ordering, `+`/`-`/`<>`, then `*`/`/`/`%`. These binary operators associate left.
Unary `!` and `-`, calls and field access bind more tightly. Use a `{ ... }` block
to group a compound expression; do not assume general parenthesized grouping.
Line comments begin with `//`. Decimal literal separators use underscores.

`echo` supports primitive diagnostic printing, including its trailing newline.
It is not a general structured-value pretty printer. Compound-value and BitArray
printing remain unsupported. Float and UtfCodepoint are not implemented.

### Tuples, lists and patterns

Tuple syntax uses `#(...)`; tuple fields use numeric access such as `pair.0`.
Lists use `[...]`, with `..tail` for a list spread or rest pattern. Patterns may be
nested and may bind/discard fields. `_` discards a value. `pattern as name` retains
the whole matched value in addition to its component bindings.

```gleam
fn head_or(xs: List(Int), fallback: Int) -> Int {
  case xs {
    [first, .._] -> first
    [] -> fallback
  }
}

pub fn main() -> Nil {
  let pair = #(7, "seven")
  let #(number, _) = pair
  echo head_or([number, 8], 0)
  echo pair.1
  Nil
}
```

A `let` pattern must be known safe under the checker’s supported refinement rules;
it is not an unchecked assertion. Case arms are checked for type consistency and
coverage within the supported pattern space. Multiple subjects, nested patterns,
compatible alternative rows and primitive integer coverage have dedicated tests.
Coverage has explicit resource/shape limits; do not interpret those tests as a
proof for every Gleam pattern form.

Guards use `if` after a pattern. They may use typed primitive operations,
short-circuit Boolean operations and supported tuple/record access. Calls,
bindings and effects are forbidden in guards. A guard does not establish coverage,
even when written `if True`; include a real fallback where required.

```gleam
fn larger(pair: #(Int, Int)) -> Int {
  case pair {
    #(a, b) if a > b -> a
    #(_, b) -> b
  }
}

pub fn main() -> Nil {
  echo larger(#(7, 4))
  Nil
}
```

### Custom types, labels and immutable records

```gleam
pub type Box(a) {
  Box(value: a, marker: Int)
}

pub fn main() -> Nil {
  let original = Box(value: 7, marker: 8)
  let updated = Box(..original, value: 14)
  case updated {
    Box(value, marker) -> {
      echo value
      echo marker
      Nil
    }
  }
  Nil
}
```

Constructors may have positional or labelled fields. Labels support shorthand and
pattern spread where qualified by tests. Duplicate/unknown labels and positional
arguments after labels are rejected. Constructor fields are checked by nominal
type, not just object shape. Zero-field constructors are values, not callable
zero-argument functions.

Generic parameters can be inferred from constructor arguments. Recursive and
mutually recursive nominal definitions are supported. Record access requires the
field's name, position and declared type to be common to possible variants, or a
statically known constructor. Updates evaluate the original once and create a new
immutable object; they do not mutate aliases. Multi-variant updates require a
known matching constructor. Retained generic fields constrain type parameters;
replaced fields can change parameters only where retained fields permit it.

Unlabelled calls preserve left-to-right evaluation. Labelled constructor values
are evaluated in declaration order, matching the qualified upstream behavior.
This is an important distinction when arguments contain effects.

Type aliases use `type Name = Type`, including parameterized aliases such as
`type Pair(a) = #(a, a)`. Aliases expand in their defining module's scope and have
no runtime wrapper. All aliases are validated, including unused declarations.
Cycles, wrong arity, unused/unbound parameters and privacy violations are rejected.

### Functions as values, closures and `use`

Named functions and anonymous functions can be values. Captures retain copied
value words in arena-owned descriptors, never references to a returned stack
frame. Anonymous parameters need annotations or a sufficiently resolved expected
function type; expected types flow through supported bindings, fields, returns,
case branches and callback contexts.

```gleam
fn make_adder(base: Int) -> fn(Int) -> Int {
  fn(n: Int) { base + n }
}

pub fn main() -> Nil {
  let add = make_adder(10)
  echo add(5)
  Nil
}
```

Captures (`function(_, value)`) and `use` lower through the supported closure/callback
representation. Callback type checking may use evidence from other arguments;
runtime evaluation order is preserved. Polymorphic named function values, labelled
ordinary function calls and general unconstrained inference remain unsupported.
See [examples/closures.gleam](examples/closures.gleam) and the callback fixtures
for qualified combinations rather than assuming every upstream callback idiom.

A complete callback example with `use`:

```gleam
fn with_value(value: a, next: fn(a) -> b) -> b {
  next(value)
}

pub fn main() -> Nil {
  let result = {
    use value <- with_value(5)
    value + 1
  }
  echo result
  Nil
}
```

### Strings, UTF-8 and implicit Result

Strings preserve validated scalar UTF-8 bytes without normalization. `<>` performs
concatenation; `==` and `!=` compare bytes. Patterns support exact literals and
literal prefixes, including `"pre" as head <> tail`. A prefix tail is an owned copy
under the current string runtime. Prefix patterns are conservatively refutable.
Source is UTF-8 validated before tokenization. Supported escapes are newline,
carriage return, tab, quote and backslash; do not assume all upstream escape forms.

The implicit prelude supplies `Result(a, e)`, `Ok` and `Error`:

```gleam
fn choose(n: Int) -> Result(String, String) {
  case n {
    0 -> Error("missing")
    _ -> Ok("prefix:" <> "λ😀")
  }
}

pub fn main() -> Nil {
  case choose(1) {
    Ok(text) -> echo text
    Error(message) -> echo message
  }
  Nil
}
```

Prelude constructors use the same generic custom-type machinery. Local declarations
can shadow prelude names under the documented namespace rules. Imported modules
do not implicitly re-export the prelude. Unused prelude definitions do not add
runtime target code merely by existing.

### Bit arrays

```gleam
pub fn main() -> Nil {
  let bytes = <<1, 2, 3>>
  case bytes {
    <<first, rest:bits>> -> {
      echo first
      echo rest == <<2, 3>>
      Nil
    }
    _ -> Nil
  }
  Nil
}
```

The subset supports byte-aligned integer construction through 64 bits, integer
patterns, endian options, static numeric or `size(N)` widths, `:bits` concatenation,
final unsized `:bits`/`:bytes` tails, and string construction with `:utf8`. Nonliteral
strings require explicit `:utf8`. Construction keeps the requested low bits;
static zero-width expressions are checked but not evaluated.

Patterns check length before reading payload. `:bits` and `:bytes` retain their
upstream coverage distinction even though generated values are byte-aligned.
Borrowed byte tails share payload and retain an owner pointer. Unsigned 64-bit
extraction above the native signed range traps rather than becoming a negative
number. Dynamic widths, non-byte-aligned segments, floats and UTF-8 codepoint
patterns remain unsupported. Byte-array equality is supported.

### Modules and imports

A file `maths.gleam` can define `pub fn twice(n: Int) -> Int { n * 2 }`.
Its sibling `main.gleam` imports it using `import maths` or `import maths as m`,
and calls `maths.twice(21)` or `m.twice(21)` respectively. Nested paths use `/`, for
example `import module_demo/numbers`. Select the directory above those modules
with `--source-root`.

Only local rooted modules are loaded. Module names/aliases use lowercase-initial
ASCII components, followed by lowercase letters, digits or underscores. No package
resolution, selective imports or automatic standard library is provided. Cycles,
missing modules, duplicate aliases, private member access and nominal cross-module
mismatches are rejected. Shared dependencies link once in deterministic import
order. Unreachable supplied raw source is not parsed merely because it was supplied.

## 3. Architecture: source to executable

### Front end

`native/lexer` validates source encoding and produces tokens with byte offsets.
`native/parser` builds the untyped AST in `native/ast`, preserving declarations,
annotations, patterns and expression structure. Precedence is explicit. Parser
errors refer to byte positions; unsupported syntax does not silently fall through
into a different language implementation.

`native/cli` expresses IO as immutable request/state values. The native runtime
interprets argument/source/output requests using owned syscalls. Module dependency
policy is in Gleam, not in the host bridge. Sources are bounded, regular rooted
files, read into immutable snapshots.

`native/project` traverses dependencies, rejects cycles, respects lexical/module
namespaces and visibility, expands aliases, and gives imported declarations unique
internal names. It forms one linked module in deterministic dependency order.
The loader carries a `PreparedSource` containing the original bytes and parsed
module, so dependency discovery and linking consume one immutable parse. This is
a per-compilation value, not a persistent cache. Existing callers may still pass
raw `Source` values; only reachable raw sources are parsed. Mixed inputs preserve
cycle, visibility, duplicate-source and deterministic-order checks.

`native/definitions` builds nominal definitions and constructor context.
`native/check` produces typed expressions and validates scope, functions, patterns,
constructor arguments and coverage. `native/type_system`, `native/coverage`,
`native/labels`, `native/free_names` and `native/bit_options` provide explicit owned
support; no external inference/parser package is hidden underneath.

### Native lowering, registers and ASM

`native/x64` lowers typed nodes into owned instruction-byte and label parts.
`native/registers` represents supported scalar regions, registers, clobbers,
branches and liveness. RAX/RCX/RDX form the scalar value pool; RDI is recovery
scratch. R14/R15 belong to the arena, so allocation must not treat them as spare
registers. Flags are modeled separately from values. Linux syscall RCX/R11
clobbers and internal-call effects must be preserved.

Scalar comparisons, short-circuit expressions and supported cases use explicit
CFG edges and successor-aware liveness. Calls preserve live pool values before
argument evaluation and copy results before restoring saves. Pressure causes real
spills. Unsupported region shapes use existing lowering rather than an optimistic
allocator with missing effects. This is not whole-function allocation across
arbitrary patterns, data values and indirect calls.

Direct returned self-calls replace parameters and jump after the prologue, including
supported returned blocks/cases. Mutual recursion and indirect/callback calls are
ordinary calls. Sibling case-local storage reserves the maximum arm footprint,
rather than summing mutually exclusive arm slots. Evaluation order and overflow
traps remain semantic constraints even when an instruction sequence could shrink.

The byte-count idiom recognizer is structural, not name based: exactly the typed,
effect-free unit-step recursion over a discarded byte/tail and unchanged base
counter can become a descriptor-length load and checked addition. Guards, effects,
other increments/base expressions or callees retain ordinary lowering.

`native/assembler` resolves owned labels and relative displacements into bytes.
`native/elf` emits ELF headers and executable payload directly. There is no external
object-file linker or assembler invocation. Actual objdump output is inspection
evidence, not the mechanism that generates executable code. See [ASM.md](ASM.md)
and [REGISTER_SPILL_SPEC.md](REGISTER_SPILL_SPEC.md) for deeper ABI/allocator detail.

### Runtime, representation and lifetime

Values use the owned one-word conventions for scalars and references. Tuples,
lists, constructors, function descriptors, strings and byte arrays have owned
layouts. Generic type checking does not create a runtime type VM. Function
values contain size/tag/code-pointer/capture words. Payload-sharing byte tails
retain a root owner; this prepares for future lifetime management but does not
constitute a collector.

The runtime obtains a non-executable RW arena with mmap. R15 advances through it;
R14 is the end. Allocations check bounds. There is no GC, reclamation or growth.
Ordinary output programs have 64 MiB; the production compiler has 512 MiB. Reserved
capacity, allocated bytes, resident pages and reachable live data are different
measurements. Exhaustion exits 71. Native Int overflow exits 70. Deep non-tail
recursion can still exhaust the stack.

The native CLI bounds each source to 128 KiB and the graph to 256 files. Rooted IO
refuses source symlinks and nonregular files. UTF-8 arguments, short/interrupted IO,
write failures, no-replace publication and non-executable-stack ELF properties
have dedicated tests. Portability is currently Linux x86-64 with the required
syscalls; macOS/ARM64 emission is future work, not an implied supported target.

## 4. Verification and optimization method

Run `python3 verify.py` for the complete qualification. Separately execute all nine
complete Gleam examples in this guide with a selected native compiler:

```sh
python3 tools/verify_guide.py out/my-gleam-native out/my-guide-receipt.json
```

The verifier builds/checks the Gleam
source, runs compiler/runtime tests, compares accepted/rejected programs with
upstream Gleam, executes actual emitted programs, records headers/disassembly,
and performs native self-rebuilds against frozen source. Upstream is an independent
development oracle; native compilation never invokes it.

A proof has a scope. Accepted fixtures must produce correct output; rejected
fixtures must fail without publishing output. Exact bytes establish reproducibility,
not speed. A simulator, inspection listing or source-ready change is not a native
execution result. The evidence JSON binds source hashes, artifact hashes and actual
observations. Historical failures and receipts remain preserved.

Optimization proceeds in separable changes: profile a real cost, inspect source
and emitted ASM, make a bounded change, qualify semantics, then compare identical
frozen inputs with multiple runs. The memory profiler inspects the arena cursor in
one newly owned child. It measures allocation volume, not object reachability;
ptrace timings are not benchmarks. Untraced benchmarks use warmups, alternating
repetitions, a pinned CPU, wait4 CPU/RSS and retained host variation. No unrelated
process or global CPU setting is changed.

[MEMORY.md](MEMORY.md) explains allocation findings and rewrites.
[BENCHMARKS.md](BENCHMARKS.md) preserves timing methodology and samples.
[JOURNEY.md](JOURNEY.md) records implementation decisions and mistakes.
[ROADMAP.md](ROADMAP.md) separates the completed self-hosting milestone from
remaining language compatibility, value semantics, optimization and targets.

The work is intentionally revisable: direct searches may later become indexes,
parse retention may change lifetime strategy, and a future collector may change
representation tradeoffs. Each measured increment must remain understandable and
correct independently of whether that architecture survives the next sequence.


## 5. Compiler API and failure boundaries

The owned API is functional and returns `Result` values:

| Entry point | Purpose |
|---|---|
| `compiler.compile(bytes)` | Compile one module named `main` to ELF bytes |
| `compiler.compile_project(entry, sources)` | Resolve a local multi-module project and compile it |
| `compiler.dependencies(bytes)` | Discover validated import names for a raw source |
| `project.prepare(source)` | Return the retained parsed source and its imports |
| `project.link(entry, sources)` | Resolve raw/prepared sources into one linked AST |
| `check.module(ast)` | Validate and produce typed functions |
| `cli_builder.build(sources)` | Emit the standalone native compiler with owned IO runtime |

`project.Source(name, content)` remains the raw API constructor. Names omit the
`.gleam` suffix and are relative to the selected source root. Prepared sources are
in-process immutable values, not a stable serialization or an untrusted external
AST interchange format. Successful preparation does not mean successful linking
or type checking. It does not permit skipping visibility or dependency checks.
The byte-generating APIs do not themselves publish files; the native request
runtime or a development IO bridge owns file access/publication.

CLI argument errors exit 2; diagnosed source/IO failures exit 1. Runtime arithmetic
and arena failures use 70 and 71. A process signal or stack exhaustion is a failure,
not a compiler diagnostic to disguise as success. Generated user programs normally
exit zero after `main`; this subset does not provide a general application OS API.

## 6. Reading the work and extending it

Start with `ast.gleam` for representable syntax, `lexer.gleam`/`parser.gleam` for
accepted text, `check.gleam` for semantics and `x64.gleam` for lowering. Adding an
AST constructor alone does not implement a feature. A change must carry through
resolution, checking, free-variable/coverage logic where relevant, machine-code
emission and meaningful accepted/rejected tests. Changes to object layout or call
ABI must also audit every owned runtime emitter that reads those layouts.

For a new optimization, keep a qualified compiler artifact, freeze the exact input,
and retain a separate source commit. Compare allocation, RSS, CPU time, wall time
and image size individually. Inspect effects and ASM before attributing a result
to instruction count. Avoid name-based shortcuts, source-copy self-hosting tricks,
foreign-string implementations and silent support claims. A rollback-friendly
increment is more useful than a broad rewrite whose semantic boundary is unclear.


### Compatibility boundary checklist

The following are explicitly outside the delivered language boundary: general
omitted-signature inference, selective/package imports, ordinary labelled function
calls, polymorphic named function values, constants, attributes, opaque/empty custom
types, Float, UtfCodepoint, arbitrary-precision literals, arbitrary Unicode escapes,
grapheme operations, unaligned/dynamic bit segments and general compound printing.
Built-in primitive type/constructor shadowing is rejected; Result/Ok/Error shadowing
has separate supported rules. This implementation does not adopt every upstream
cross-target integer behavior merely because the syntax is shared.

Structural equality is implemented for qualified concrete shapes, including
recursive data, lists, tuples, strings and bit arrays, but erased generic fields
or function values cannot be guessed. Shape graphs are bounded to 128 nodes;
unknown runtime type information is not reconstructed by unsafe pointer comparison.
Future changes must keep unsupported cases diagnosed rather than silently broadening
comparison semantics. See the equality fixtures and runtime implementation.

The native target is not a POSIX/C library environment. Generated user programs do
not acquire filesystem, socket or process facilities just because the compiler's
own explicitly checked effect runner implements source/output IO. Compiler bootstrap
and development commands are not language standard-library imports.
