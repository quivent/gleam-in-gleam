# Self-hosting proof

**The supported-subset compiler rebuilds itself natively.** The first milestone's
previously defined acceptance scope is met; full upstream Gleam compatibility is
still incomplete.

## Exact observed chain

1. The upstream Gleam/JavaScript bootstrap emits stage 1, our native compiler.
2. Stage 1 reads a frozen copy of all 27 actual compiler modules through the owned
   file runner and `--build-compiler`, producing stage 2.
3. Stage 2 repeats the rebuild from those same bytes, producing stage 3.
4. All three are 637,999 bytes with SHA256
   `3a8063b7582cb04e53c7443110403dc80f7c757fab0a893add0089a367ca8b65`.
5. Stage 3 compiles 371 corpus cases: 251 accepted, 120 rejected. Every accepted
   output is byte-identical to bootstrap output and executes correctly. Rejections
   have controlled compiler exits and publish no output.
6. A changed version literal in a separate source copy produces a different native
   compiler, reports the changed version and matches a fresh bootstrap reference.

The rebuilds and corpus run with an empty PATH. Actual ELF headers have no dynamic
loader/segment and an RW non-executable stack. No upstream compiler, Node, libc,
external assembler/linker or bundled VM is invoked by the native compiler.
Development/bootstrap verification tooling remains separate.

## Repeat

```sh
gleam build --warnings-as-errors
node build-native.mjs out/stage1
./out/stage1 --build-compiler out/stage2 --source-root src
./out/stage2 --build-compiler out/stage3 --source-root src
cmp out/stage1 out/stage2
cmp out/stage2 out/stage3
python3 verify.py
```

Outputs must be new and source bytes unchanged. The verifier freezes its inputs
and records exact per-module/fixture hashes and per-case observations.

## Bounds and remaining work

The native CLI accepts 128 KiB/source, 256 files, and uses a bounded 512 MiB arena.
The earlier first-milestone rebuild allocated 368,525,376 bytes and peaked at 360,320 KiB RSS.
Ordinary emitted programs retain 64 MiB. No collection or growth exists.
Direct returned self-calls are optimized through blocks/cases; mutual/indirect
calls and continuation callbacks still use ordinary calls. Deep non-tail syntax
can still exhaust the stack. Full compatibility, exact larger literals, erased
value equality, measured optimization/register allocation and targets remain open.

## Evidence

* [Complete qualification](evidence/control-flow-qualification.json): 729 checks,
  371 fresh independent upstream comparisons and all 16 native example runs.
* [Native rebuilds and corpus](evidence/control-flow-native-rebuilds.json): exact
  sources, image hashes, source-sensitivity control and individual native cases.
* [Native IO qualification](evidence/control-flow-io-verification.json): 59 targeted
  checks, actual short IO, errors, preservation and ELF headers.
* [Measured scale frontier](evidence/self-hosting-scale-frontier.json): retained
  initial stack/heap failures and measured fixes; snapshots are not peak stack.
* [History](JOURNEY.md) and [remaining roadmap](ROADMAP.md).

Older native API and 16 KiB CLI evidence remains under its original filenames.
Those component proofs alone were not self-hosting. No installed compiler, Crew
session or unrelated executable was replaced.

The current emitter uses bounded look-ahead to retain left operands in RCX when
the right is a safe leaf. Calls keep their spills. General liveness/register
allocation and broader spill-slot reuse remain open in [the spec](REGISTER_SPILL_SPEC.md).
First-milestone evidence remains under self-hosting-*; later qualification is
separately retained under leaf-register-* and branch-slots-*.

Sibling-case locals now reuse slots with a maximum frame reservation; whole-function liveness
and allocation remain open. A real bounded non-tail recursion comparison and fixed-
source frame measurements are retained under branch-slots-*.

Typed integer regions now use register allocation and backward liveness with
explicit flags and real spills. Indirect/non-integer calls and control flow remain region boundaries;
whole-function CFG allocation remains open. Current evidence is separately
retained under integer-regions-*, including a seeded 100-expression oracle.

Named Int calls with supported integer arguments now participate in typed
allocation with caller saves and an explicit volatile-register mask. Whole-function
control-flow allocation and indirect/non-integer call regions remain open. The
named-calls-* receipts preserve this current qualification and both stress modes.

Scalar branches/short-circuit expressions now use explicit CFG edges and join
liveness. General data/guarded patterns remain legacy boundaries. Current proof
is under control-flow-*; [BENCHMARKS.md](BENCHMARKS.md) reports actual repeated
measurements without claiming whole-function allocation or a broad speedup.
