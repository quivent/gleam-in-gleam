# Progress toward self-hosting

Current status: **working native compiler for a growing, tested Gleam subset;
not a self-hosted compiler or a replacement for upstream Gleam yet.** A feature
count or test count is not a defensible completion percentage.

| Area | Actual evidence | Remaining work relevant to this compiler's own source |
| --- | --- | --- |
| Frontend | Own Gleam lexer/parser for typed functions, data types, records, updates, imports, aliases, guards and patterns | Multiple case subjects, alternative patterns, remaining bit-array forms and more syntax |
| Data types | Tuples/lists, recursive generic ADTs, labels, record access and byte-aligned bit arrays execute natively | Non-string structural equality, full inference/coverage and remaining language semantics |
| Functions | Explicit generic signatures, direct recursion, named values, captured closures and `use` execute natively | polymorphic function values, omitted signatures and full inference |
| Machine code | Own x86-64 instruction emitter, relative relocations and standalone ELF writer | Remaining operations and eventual additional targets |
| Runtime | Primitive printing, owned strings and guarded 64 MiB RW arena; no external libraries | Collection, compiler file/argument IO, remaining byte/string primitives and robust IO |
| Project compilation | Local import graph, visibility and namespaces resolved in Gleam; own native relocation/linking | Selective imports/packages and native compiler file IO/entrypoint |
| Bootstrap | Upstream Gleam builds the implementation to JS; that implementation emits real native programs | Native compiler stage 1, native stage 2 and byte-for-byte bootstrap comparison |

The current strings/prelude milestone has 437 passing checks and 173 agreeing upstream
accept/reject comparisons. Pure oracle functions are compiled by upstream and
compared with executed native results. Accepted entrypoint fixtures also compare
observable output/evaluation order. These are concrete subset checks, not a full
upstream conformance suite.

Every delivered example executes without a dynamic loader or shared libraries.
**The compiler still requires the bootstrap toolchain.** The example binary sizes
do not establish the size of a finished native compiler.

## Next actions

1. Add remaining source features (multiple subjects, alternative patterns,
   structural equality, inference and bit-array forms) and import forms with upstream differential tests.
2. Implement native compiler file/argument IO and owned memory collection. Keep
   development/oracle dependencies separate from final execution requirements.
3. Compile the complete compiler source into a native stage-1 compiler. Use that
   executable to compile the same source again, and compare stage-1/stage-2
   outputs and test results. Only then claim native self-hosting.

Correctness precedes optimization. Retain emitted-ASM inspection, zero declared
package dependencies and unchanged historical evidence throughout.

Closures currently retain copied captures in the owned arena. The descriptor ABI
is shared with named values, with a saved descriptor word passed to indirect
callees. This establishes tested lifetime semantics without stack captures; it
does not establish memory reclamation or a finalized optimized ABI.

Record updates now lower to a saved original and immutable reconstruction. Their
type-changing behavior and declaration-order effects match the tested upstream
cases. This removes another syntax dependency in our own source without adding
runtime dependencies or establishing native self-hosting.

The byte-aligned bit-array subset now covers the fixed-width integer encoding,
concatenation and byte/rest matching used extensively by our emitter and lexer.
Slices carry an explicit owner pointer for later collection. This is not complete
bit-array compatibility: unaligned bits, dynamic sizing, UTF-8 codepoint patterns/float segments and
structural comparison remain open. Native file IO, remaining string operations, other
syntax/inference and module integration are still required for stage 1.

Local modules now resolve and link into one native image without an external
linker or runtime module lookup. The bootstrap reads source bytes; project policy
is in Gleam. This removes a project-compilation barrier, but does not establish
native self-compilation: several constructs used by the compiler and its native
entrypoint/runtime are still missing. Completion is still measured by actual
stage-1/stage-2 rebuilding, not a feature percentage.

Transparent generic aliases and restricted pure case guards now execute with
upstream-checked scope, visibility and fallthrough behavior. Alias definitions are
erased; guards use normal native branches and capture lifetime. This removes two
more source-language barriers while preserving every prior example's binary. Remaining
string/prelude operations, inference/syntax and
native IO/collection still prevent actual stage-1/stage-2 self-hosting.

Dynamic strings, exact equality, prefix/literal patterns and UTF-8 byte construction
now execute natively. Implicit Result/Ok/Error work across modules with local
shadowing. The compiler-owned UTF-8 validator itself has been compiled and executed
by this compiler, while independent host-oracle comparisons cover more input cases.
This establishes one component, not the complete native compiler. Float/codepoints,
multiple subjects/alternative patterns, structural equality and native IO/collection
remain open; no stage-1/stage-2 claim is made.
