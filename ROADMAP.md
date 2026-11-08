# Remaining work

Updated 2026-11-08. Correctness comes first; inspect generated ASM throughout.
Compiler logic stays in Gleam, with zero third-party compiler/runtime dependencies.

## Subjective progress

**Subjective progress toward a usable, self-hosting Linux x86-64 compiler: 70%**

```text
[██████████████░░░░░░] 70%
```

Estimate as of 2026-11-08. The frontend, backend, native API and bounded native
file-based CLI work. That raises my subjective estimate from 65% to 70%.
Substantial uncertainty remains in full-size stack/memory reliability, broader
native-path testing and an actual self-rebuild; this is not a forecast.

For this bar, **100% means** a usable native Linux x86-64 CLI that compiles the
complete compiler source, produces a byte-identical successive rebuild, and
passes the native-path qualification checks with zero third-party runtime
requirements. Full upstream Gleam compatibility, other targets and subsequent
optimization remain separate roadmap work; this bar does not claim those are
70% complete. It is not calculated from test counts or a delivery-date forecast.
Update it when new evidence changes the assessment.

## Verified starting point

The native CLI reads files/imports, compiles all sixteen tracked examples to
bootstrap-identical executables, and executes the outputs. Its input bound is
16 KiB per source; it does not yet compile the complete compiler source tree.
Current qualification is **631 passing tests and 297 fresh upstream comparisons**.
The 59 targeted CLI checks cover real short IO, EINTR, publication/error cleanup,
Unicode paths, preservation and ABI validation. See the
[CLI spec](NATIVE_CLI_SPEC.md), [IO evidence](evidence/native-cli-io-verification.json)
and [current verification](evidence/native-cli-verification.json).

The earlier 498,418-byte native API-plus-driver result and 572-test baseline remain
historical in [their receipt](evidence/integers-coverage-verification.json).
A complete compiler rebuild and full upstream Gleam compatibility are unfinished.

## Priorities and completion evidence

1. **Usable native compiler CLI — delivered for bounded inputs.**
   Read arguments and source files, resolve local modules, write executables and
   report errors through owned native IO. Handle partial reads/writes, interrupted
   syscalls and failures correctly. Complete when a standalone executable compiles
   a supported source tree from the terminal without Node or upstream tooling at
   runtime, and its emitted programs execute correctly. This bounded milestone
   now passes; lifting its 16 KiB source bound belongs to priority 2.

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
   does not. Use the dedicated `cli_builder.build` path for the compiler's own
   effect-runner entry; a native self-build command still needs to be connected.

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
