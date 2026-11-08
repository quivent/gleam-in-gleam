# Progress toward self-hosting

**The complete compiler API now compiles and runs natively. The native CLI and
stage-2 self-rebuild are not yet proved.** This remains a tested Gleam subset,
not a replacement for upstream or a defensible completion percentage.

The repeatable `node test/probe-compiler-api.mjs` builds all 22 actual compiler
modules plus `test/owned-compiler-api-driver.source` into a standalone Linux
x86-64 ELF. That native program compiles two embedded Gleam sources. The probe
extracts both resulting ELF files, compares their exact bytes with bootstrap
compiler output, and executes them: outputs are `7` and `7,10` respectively.
The second source exercises a wide integer pattern, tuple alias and field read.

The native API-plus-driver image is 498,418 bytes. It and both emitted programs
have no dynamic loader or dynamic segment and have a non-executable stack.
Source, driver and executable hashes plus real execution results are retained in
`evidence/complete-api-wide-integers-probe.json`. This is an actual native compiler
core executing, not JavaScript wrapped in an executable. The initial image is
still produced through the official Gleam-to-JS bootstrap and our own backend.

| Area | Actual evidence | Remaining work |
| --- | --- | --- |
| Source compilation | All actual compiler modules compile to native code under a bounded driver | Native compilation of a complete compiler rebuild input |
| Native compiler execution | Two programs emitted, byte-identical to bootstrap output, both execute correctly | Broader native-path qualification and self-rebuild |
| CLI/IO | Bootstrap supplies ordinary source-file and argument IO; native probe uses embedded sources and stdout | Owned native arguments/files, robust partial IO and errors |
| Language | Recursive ADTs, closures/use, aliases/guards, product cases, structural equality and exact 53-bit literals | Remaining upstream syntax/inference/imports, erased equality, exact larger literals |
| Runtime | Owned strings/bytes, direct syscalls and checked 64 MiB arena | Native tail-call elimination, collection/allocation scaling |
| Targets/dependencies | Own x86-64 emitter/relocator/ELF, no external runtime/assembler/linker/libc/packages | Additional architectures/OS formats |

Current qualification: **572/572** tests and **297/297** fresh upstream
comparisons. All fifteen older example hashes remain unchanged. The two native
compiler output/execute checks are recorded separately from that test count in
`evidence/integers-coverage-verification.json` and its linked API proof.

## Next acceptance steps

1. Supply an owned native compiler CLI for arguments/source files, keeping the
   development bootstrap separate from runtime dependencies.
2. Compile complete compiler inputs natively and fix measured resource limits.
   The append change avoids bootstrap stack overflow but uses an extra reversed
   prefix. Its traversals still consume stack in native code until TCO exists;
   the arena has no collection. Do not assume small-input success proves scale.
3. Rebuild the exact compiler source with the native compiler, compare the
   stage-1/stage-2 bytes and execute the rebuilt compiler's checks. Only then
   claim native self-hosting.

Historical component proofs for UTF-8, core, type-system and equality planner
remain in evidence and JOURNEY.md. Earlier alias and literal rejections are
preserved under their original receipt names. The default file-based CLI still
uses Node; no installed compiler or Crew process has been replaced.
