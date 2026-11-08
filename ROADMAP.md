# Remaining work

Updated 2026-11-08. Correctness comes first; inspect generated ASM throughout.
Compiler logic stays in Gleam, with zero third-party compiler/runtime dependencies.

## Verified starting point

The complete compiler API runs as a 498,418-byte standalone Linux x86-64 ELF,
including its bounded test driver. It compiled two programs whose bytes exactly
match bootstrap output, and both programs execute correctly. Qualification is
572 passing tests and 297 fresh upstream comparisons. The two native compiler
output/execute checks are separate from those test counts.

The ordinary file-based CLI still uses the Node bootstrap. A native CLI, complete
Gleam compatibility and a compiler rebuilding itself remain unfinished. See
[the native API proof](evidence/complete-api-wide-integers-probe.json),
[verification](evidence/integers-coverage-verification.json) and
[self-hosting status](SELF_HOSTING.md).

## Priorities and completion evidence

1. **Usable native compiler CLI — next deliverable.**
   Read arguments and source files, resolve local modules, write executables and
   report errors through owned native IO. Handle partial reads/writes, interrupted
   syscalls and failures correctly. Complete when a standalone executable compiles
   a supported source tree from the terminal without Node or upstream tooling at
   runtime, and its emitted programs execute correctly.

2. **Full-size compilation reliability.**
   Exercise large inputs and complete compiler inputs. Address measured stack and
   allocation limits: the current arena is fixed at 64 MiB with no collection,
   native calls have no tail-call elimination, and some utilities create large
   intermediate lists/byte arrays. Complete this milestone when representative
   full-size inputs compile correctly with recorded resource usage and explicit
   failure behavior. Choose runtime changes from evidence rather than assuming
   small-input success proves scale.

3. **Broader native-compiler testing.**
   Run the wider correctness suite through the native compiler path. Current
   native API qualification covers two emitted programs; the existing 572-test
   suite does not mean all 572 cases were compiled by that native API. Compare
   native/bootstrap output and observable behavior, including rejection cases,
   modules, closures, recursive data, patterns, strings and byte arrays.

4. **Self-hosting proof.**
   Have the native compiler compile its own complete source, execute the rebuilt
   compiler, and compare successive identical-input builds byte-for-byte. Retain
   exact input hashes, commands, compiler/output hashes and test results. Only an
   actual rebuild establishes this milestone; compiling embedded sample programs
   does not.

5. **Remaining Gleam language compatibility.**
   Extend general inference, polymorphic function values, selective/package
   imports, labelled function calls, constants, attributes, opaque types, remaining
   patterns, floats and Unicode operations. Qualify each bounded addition against
   upstream behavior and keep unsupported features explicit. Full compatibility
   remains a separate goal from this compiler rebuilding its own supported source.

6. **Complete value semantics.**
   Add exact larger integer literals beyond the current 2^53-1 magnitude bound,
   equality involving erased generic types, compound-value printing and remaining
   bit-array operations. Do not round unsupported literals or guess erased layouts.
   Retain precise native arithmetic limits and upstream semantic comparisons.

7. **Measured optimization after correctness.**
   Benchmark compilation speed, generated-code execution, allocation and binary
   size on reproducible workloads. Inspect ASM and optimize demonstrated costs,
   retaining correctness checks. Binary size alone does not establish speed; no
   language-wide performance claim follows from the current example measurements.

8. **Additional targets and distribution.**
   Add ARM64/macOS instruction emission, executable format and OS/runtime support.
   Verify those targets directly. Package usable standalone releases with clear
   install/update instructions, supported-target declarations and artifact hashes.

## Working rules

Preserve source, history and verification receipts. Keep development/bootstrap
requirements separate from delivered native dependencies. Do not replace the
installed Crew compiler or disrupt active sessions. Update this roadmap and the
[current status](SELF_HOSTING.md) as milestones gain real evidence; retain the
implementation history in [JOURNEY.md](JOURNEY.md).
