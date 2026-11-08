# Remaining work

Updated 2026-11-08. Correctness comes first; inspect generated ASM throughout.
Compiler logic stays in Gleam, with zero third-party compiler/runtime dependencies.

[Interactive version](docs/roadmap.html) · [How to open/use it](docs/README.md) ·
[Next implementation spec](FULL_SIZE_RELIABILITY_SPEC.md)

The interactive view has the same eight workstreams, with spec outlines,
acceptance criteria, evidence and browser-local review notes. It does not promote
review marks into verified status.

## First milestone achieved

```text
[████████████████████] 100% — supported-subset self-hosting
```

The former subjective 70% bar had a defined finish line: native file compilation
of the complete compiler input, byte-identical successive rebuilds and native-path
qualification. That finish line is now verified. This is not a full-upstream
compatibility score. The extension workstreams below remain incomplete.

## Verified starting point

All 27 compiler modules rebuild through the native effect-runner entry. Stages
1, 2 and 3 are byte-identical: 613,842 bytes, SHA256
`df8df2222b511f403f7488472dada651a0a8a5c8010a199fe88046e8e039bb7b`.
The stage-3 compiler passes 351 corpus cases; every accepted output matches the
bootstrap bytes and executes correctly. Full qualification includes 702 tests,
351 independent upstream comparisons, 16 examples and 59 native IO checks.
See [the proof](SELF_HOSTING.md) and
[qualification receipt](evidence/integer-regions-qualification.json).

The explicit limits are 128 KiB/source and 512 MiB compiler arena, without GC.
Ordinary output programs keep their 64 MiB arena. Historical 16 KiB CLI and API
receipts remain preserved under their original names.

## Priorities and completion evidence

1. **Usable native compiler CLI — verified within explicit limits.**
   Owned arguments, rooted reads, imports, complete writes and no-replace
   publication. The syscall and preservation tests still pass after scale changes.

2. **Full-size compilation reliability — verified for the actual compiler graph.**
   Actual stack frames identified the UTF-8 recursion failure. Returned direct
   self-calls now loop after the prologue, including blocks and cases. Balanced
   byte concatenation and reverse closure accumulation remove measured copying
   frontiers. The first milestone rebuild allocated 368,525,376 bytes; its observed peak RSS was
   360,320 KiB. These bounded measurements do not prove arbitrary-input reliability.
   Deep non-tail recursion and arena exhaustion remain explicit limits.

3. **Broader native-compiler testing — current corpus verified.**
   All 351 positive/negative fixtures go through stage 3, with exact accepted
   image/output comparisons. The separate upstream comparisons are independent.
   Expand this corpus alongside every new language/runtime feature.

4. **Self-hosting proof — verified.**
   Two native self-rebuilds from the exact frozen source match the seed. A separate
   changed-source control produces the correctly changed compiler. Source hashes,
   stage images, native corpus and ELF observations are retained in
   [the rebuild receipt](evidence/integer-regions-native-rebuilds.json).

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

7. **Measured optimization after correctness — first bounded increment verified.**
   Leaf operand look-ahead removes 260 static push/pop pairs and 451 instructions
   on fixed source; calls retain their spills. Whole-function register allocation,
   control-flow liveness and broader spill-slot reuse remain open in [the spec](REGISTER_SPILL_SPEC.md).
   Sibling case arms also share their local slots; fixed-source named frame sums
   fall about 29%. The recorded 64 KiB non-tail workload now succeeds.
   Typed integer regions now allocate three registers, spill on pressure and use
   explicit register/flags liveness. Calls and control flow remain boundaries.
   Benchmark compilation speed, generated-code execution, allocation and binary
   size on reproducible workloads. Inspect ASM and optimize demonstrated costs,
   retaining correctness checks. Jay specifically requested look-ahead to avoid
   redundant intermediate work and register allocation/spilling. Measure emitted
   frame traffic first; preserve left-to-right effects, call/syscall clobbers and
   spill live values only where needed. Binary size alone does not establish speed; no
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
