# Progress toward self-hosting

Current status: **working native compiler for a growing, tested Gleam subset;
not a self-hosted compiler or a replacement for upstream Gleam yet.** A feature
count or test count is not a defensible completion percentage.

| Area | Actual evidence | Remaining work relevant to this compiler's own source |
| --- | --- | --- |
| Frontend | Own Gleam lexer/parser for typed functions, data types, records and patterns | Imports, updates, bit arrays and more syntax |
| Data types | Tuples/lists, recursive generic ADTs, labels and record access execute natively | Full inference/coverage, equality, dynamic strings, remaining language semantics |
| Functions | Explicit generic signatures, direct recursion, named values, captured closures and `use` execute natively | polymorphic function values, omitted signatures and full inference |
| Machine code | Own x86-64 instruction emitter, relative relocations and standalone ELF writer | Remaining operations and eventual additional targets |
| Runtime | Primitive printing and guarded 64 MiB RW arena; no external libraries | Collection, compiler file/argument IO, byte/string primitives and robust IO |
| Project compilation | Single source module compiled through a Node IO bootstrap | Module graph/loading/linking and a native compiler entrypoint |
| Bootstrap | Upstream Gleam builds the implementation to JS; that implementation emits real native programs | Native compiler stage 1, native stage 2 and byte-for-byte bootstrap comparison |

The current closures milestone has 210 passing checks and 31 agreeing upstream
accept/reject comparisons. Pure oracle functions are compiled by upstream and
compared with executed native results. Accepted entrypoint fixtures also compare
observable output/evaluation order. These are concrete subset checks, not a full
upstream conformance suite.

Every delivered example executes without a dynamic loader or shared libraries.
**The compiler still requires the bootstrap toolchain.** The example binary sizes
do not establish the size of a finished native compiler.

## Next actions

1. Add the compiler's record-update, bit-array and module features with upstream
   differential tests. Continue closing explicit inference/semantic gaps.
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
