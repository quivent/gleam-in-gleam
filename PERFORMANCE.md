# Surface performance baselines

Measured on 2026-11-08. These are small, reproducible comparisons on one shared
Linux/Icelake host, with all results checked. They establish a baseline for this
compiler, not a language-wide ranking or a claim of GCC performance parity.

## Current full-source result: fused layout and shared context

The qualified source is `9472a75`: 28 modules, 275,945 source bytes,
766 tests, 394 independent upstream comparisons and two byte-identical native
self-rebuilds. Five measured repeats follow a warm-up for **each of three tools**.
All compile the same frozen input in fresh directories on one pinned CPU; order
rotates and reverses. The original Gleam 1.19.2 emits JavaScript; both GTA versions
emit standalone ELF. Targets and supported language scope differ.

| Same full input | Original Gleam → JS | Previous GTA → ELF | Fused GTA → ELF |
|---|---:|---:|---:|
| Median CPU | 0.600387 s | 5.783283 s | **0.483816 s** |
| Median elapsed | 0.713376 s | 6.869283 s | **0.576871 s** |
| Elapsed min–max | 0.633–0.919 s | 6.702–7.252 s | 0.546–1.068 s |
| Maximum RSS | 44.45 MiB | 175.88 MiB | 200.25 MiB |

The combined pass uses **91.63% less CPU** than previous GTA
(**11.95×** throughput on this input), and **19.42% less CPU** than
original Gleam in this cohort. Original/fused elapsed ranges overlap on the shared
host; these medians do not establish a universal compiler ranking. Earlier small
program timings remain historical and are not substituted for this full build.

### What changed

The phase trace put about 97% of the initial full build in assembly. The old
assembler scanned a flat label list for duplicate detection and each relocation.
With L labels and R references this admitted quadratic work. The new layout walk
captures offsets, an immutable AVL label index, and reversed output chunks together.
A chunk-only walk resolves relocations and constructs final order; it does not
revisit instruction spans or remeasure their lengths. Keys use a bounded hash and
full-name collision buckets: hash equality never replaces string equality.
Tree paths are logarithmic in distinct hashes; adversarial collision buckets can
still require linear searches. Balanced concatenation remains a separate operation.

Linking now retains its validated definition context for checking and codegen:
three context collections become one. Validation-only traversals consume success
results directly instead of allocating lists that are thrown away. The measured
improvement belongs to the **combined pass**; these subchanges were not individually
isolated in the final timing cohort.

### Preserved behavior and cost

Both native tools emit **the same 660,173-byte compiler**, SHA256
`55bc7dd3b96886593ae18806205399dfd27be2d88a50fe9073d692c0f885ebd4`,
from the frozen input. All repeats are deterministic. This is a compilation win,
not an improvement to generated-program runtime. Tests cover full-name hash
collisions, duplicate labels, missing references in source order, UTF-8 labels,
large mixed forward/backward relocations and deep spans. Native and original-Gleam
execution agree on the dedicated assembler/validation probe.

The faster immutable index costs memory: **24.38 MiB more peak RSS**.
Same-input allocation traces rise from 183,603,232 to 209,172,536 bytes; these are
allocation volumes, not reachable-object measurements. No GC, runtime dependency,
LLVM, assembler or linker was added to the delivered compiler. Compact index/hash
traversal storage and larger varied-source scaling are the next measurements.

[All 15 samples and exact input/output hashes](evidence/fusion-full-compilation.json),
[qualification](evidence/fusion-qualification.json),
[native rebuilds](evidence/fusion-native-rebuilds.json),
[execution oracle](evidence/fusion-execution.json),
[before allocation trace](evidence/fusion-same-input-before-phases.json),
[after allocation trace](evidence/fusion-same-input-after-phases.json).

```sh
python3 tools/benchmark_upstream_compile.py out/fusion-final/compiler out/fusion-repeat.json \
  --qualification evidence/fusion-qualification.json \
  --native-baseline out/allocation-profile/flags-v1/compiler
```

The previous native image is retained locally with its original hash; fresh
checkouts must reproduce or provide it before using that comparison option.
The older comparison below stays intact as the record that exposed the gap.

## Historical first comparison: original upstream Gleam compilation

This comparison uses the original **Gleam 1.19.2 compiler**, not our previous
native version and not our own compiler running under Node.

Five alternating measured repeats after a warm-up compile the same frozen
**28 modules / 270,280 source bytes**. Every trial has a fresh build directory.
The original compiler emits JavaScript; self-hosted GTA emits native ELF. Their
backend work and supported-language scope differ, so the result is a practical
same-source build baseline rather than an identical-backend contest.

| Full compiler source | Original Gleam → JS | GTA → native ELF |
|---|---:|---:|
| Median CPU | **0.587 s** | **5.538 s** |
| Median elapsed | **0.773 s** | **6.323 s** |
| Elapsed min–max | 0.668–0.788 s | 5.637–6.725 s |
| Maximum RSS | 44.2 MiB | 173.3 MiB |
| Generated payload | 867,378 JS bytes, Node excluded | 653,202 standalone ELF bytes |

On this larger source set, original Gleam is about **9.43× faster by CPU** and
**8.18× by elapsed time**. The tiny-source compilation rows measured earlier favor
GTA, so startup behavior must not be extrapolated to whole-project compilation.
The README's primary compilation table now includes both sizes of workload, with
percentage changes calculated from raw receipts.

Every GTA self-build matches the qualified native compiler hash. Every upstream
build emits the complete set of 28 JavaScript modules deterministically. An untimed
probe imports that freshly compiled compiler implementation, emits a native test
program and executes it with the expected output 45. That qualification step is
not included in original-Gleam compilation timing.

[Full-source raw samples, input hashes and qualification](evidence/original-gleam-full-compilation.json).

```sh
python3 tools/benchmark_upstream_compile.py out/gleam-native out/original-gleam.json
```

## What ran

| Variant | Implementation |
|---|---|
| Native | Our qualified Gleam-in-Gleam compiler, 647,417-byte standalone image |
| Gleam / Node | Upstream Gleam 1.19.2 JavaScript target on Node v22.23.3 |
| C / O2 | GCC 13.3.0, `-O2 -std=c11` |
| C / O3 | GCC 13.3.0, `-O3 -std=c11` |

The two Gleam variants compile **identical source bytes**. C expresses equivalent
algorithms. Checksums come from independent Python calculations, including exact
integer recurrence, branch sums, iterative Fibonacci and closed-form list sums.
All values stay within the common exact range of native signed Int, JS Number
and C int64_t. Their general language semantics are not interchangeable.

Each workload has one warm-up per variant, then five measured runs. Variant order
rotates and reverses to avoid always putting one implementation first. Every
runtime sample starts a new process; these are not steady-state-only JIT results.
Compilation uses fresh project/build directories; OS caches are uncontrolled, so
there is no cold-cache claim. Targets run on the same pinned CPU. No unrelated
process, global CPU governor, active session or installed compiler was changed.

[All 200 measured samples, sources, checksums, hashes, sizes, ranges and environment](evidence/surface-baselines.json).

## Generated-program execution

Median **CPU time**, milliseconds, including process startup:

| Workload | Native | Gleam / Node | GCC O2 | GCC O3 |
|---|---:|---:|---:|---:|
| Startup / return 45 | 0.458 | 76.220 | 1.213 | 1.184 |
| Integer recurrence, 20M steps | 329.348 | 591.356 | 153.751 | 154.825 |
| Branch + named call, 20M steps | 350.318 | 254.984 | 74.573 | 74.344 |
| Recursive Fibonacci, n=35 | 229.080 | 485.863 | 72.113 | 70.215 |
| Build/map/sum, 500K list elements | 47.597 | 358.231 | 19.220 | 18.997 |

Native wins against fresh-process Gleam/Node in recurrence, Fibonacci and list
processing, but loses in branch/call. Optimized C wins all four longer workloads.
The startup row describes launch cost and is too short for broad CPU-throughput
claims. It must not be used as a multiplier for long-running applications.

The concrete next investigations are emitted code for constant remainder/division,
branch/value selection, call preservation and recursive lowering. The measurements
do not isolate which instruction explains each difference. Inspect the code and
prove a bounded change before assigning causality.

[Reproduced exact measured hashes and actual disassembly for all 12 longer native/C artifacts](evidence/surface-disassembly-verification.json).
Native listings include the raw payload and trailing constants; GCC listings are
ELF text disassemblies. These listings are observations, not external assembly
steps in our compiler.

## Compilation

Median **CPU time**, milliseconds, including compiler process startup:

| Source | Native | Gleam → JS | GCC O2 | GCC O3 |
|---|---:|---:|---:|---:|
| Startup | 0.942 | 10.918 | 83.352 | 83.603 |
| Integer recurrence | 1.418 | 11.895 | 95.516 | 93.285 |
| Branch + call | 1.462 | 11.825 | 94.163 | 94.828 |
| Fibonacci | 1.193 | 11.137 | 159.756 | 173.391 |
| List pipeline | 1.690 | 13.215 | 106.034 | 106.864 |

Our small compiler emits these programs quickly. This does not establish whole-
project compilation superiority: Gleam runs project setup and emits JavaScript;
GCC parses C headers, optimizes, assembles and links; our compiler handles a smaller
language and emits ELF directly. The test intentionally records their supported
end-to-end commands, not an invented equal amount of compiler work.

All successful repeated artifacts are deterministic within each workload/variant.
The resulting programs run and return the independently expected value. Compiler
CPU time and generated-program CPU time remain separate results.

## Runtime memory and artifact size

For the list workload:

| Variant | Maximum observed process RSS | Target artifact bytes |
|---|---:|---:|
| Native | 31,232 KiB (30.5 MiB) | 1,127 |
| Gleam / Node | 116,736 KiB (114.0 MiB) | 49,468 generated JS bytes |
| GCC O2 | 16,768 KiB (16.4 MiB) | 16,096 |
| GCC O3 | 16,768 KiB (16.4 MiB) | 16,096 |

Native output is standalone ELF. JS size is the sum of generated `.mjs` files and
**excludes Node**. C is a dynamically linked ELF and **excludes libc/loader**.
Comparing those byte counts does not imply identical deployment footprints.

Allocation strategies also differ: native uses a bounded bump arena; upstream JS
uses managed objects; the C list baseline explicitly reserves one pool for both
lists, without a per-node malloc call. The list order, transformations and sum are
equivalent, but allocator policies and object layouts are not artificially forced
to match. No collector has been added to our compiler/runtime.

RSS comes from a small C measurement parent using wait4, which avoids inheriting
the Python orchestrator's larger resident image into the measured child. The child
sets affinity and resource limits, then execs the actual target. RSS includes
launcher/loader setup, and very small processes approach the kernel sampling floor;
a zero report would mean below visibility rather than zero physical memory. CPU
uses microsecond-resolution user/system rusage, and wall uses CLOCK_MONOTONIC.
For compiler drivers, waited descendants contribute to the observed child usage.
The measurement helper and C references are **development tools**, never delivered
native compiler dependencies.

## Repeat

```sh
python3 tools/benchmark_surface.py out/gleam-native out/surface-baselines.json
```

Defaults are five repetitions, 20M recurrence/branch steps, Fibonacci35 and 500K
list elements. `--gleam PATH`, `--repetitions N` (at least five), and `--iterations N`
are supported. It requires GCC to build the small process-measurement helper, plus
upstream Gleam and Node for those comparison lanes. Owned temporary projects and
binaries are removed after the receipt is written; exact source and artifact hashes
remain in the receipt. The separate disassembly receipt binds reproduced artifacts
to the measured hashes.

Two early failed harness attempts are preserved. The first used parentheses where
Gleam requires a grouping block. The attempted fix also changed the C expression,
which the second run rejected. These are benchmark-authoring mistakes, not compiler
failures or performance measurements. The successful receipt contains only valid,
checked workload results; the earlier receipts retain their actual failure details:
[first attempt](evidence/surface-baselines-first-attempt.json),
[second attempt](evidence/surface-baselines-second-attempt.json).

## Paired follow-up: defer Boolean materialization

The next runtime change is compiler source commit `fa468e6`, native image 653,202
bytes, SHA256 `1068e2110485d9e37a3e479fb87a0d5f9ace8c3aca0bf9ecd3194cff3468056c`.
Complementary unguarded cases over integer comparisons consume machine flags
directly; comparison operands retain their order and only the selected arm
executes. The implementation and language semantics remain Gleam.

The new run includes **both** the preceding native compiler and the candidate in
the same five-variant rotating cohort, alongside unchanged Node/GCC comparisons.
It records 250 measured samples. All five workloads use the identical Gleam/C source
and independent expected results from the first cohort. Compare before/after
within this run, not medians taken from different shared-host runs.

Median CPU milliseconds, including fresh-process startup:

| Workload | Native before | Native after | Gleam/Node | GCC O2 | GCC O3 |
|---|---:|---:|---:|---:|---:|
| Startup | 0.362 | 0.354 | 61.917 | 1.079 | 1.139 |
| Integer recurrence | 322.359 | 323.890 | 582.558 | 153.829 | 153.539 |
| Branch + call | 327.907 | **299.503** | 187.250 | 63.884 | 64.215 |
| Recursive Fibonacci | 232.507 | **194.260** | 494.782 | 76.028 | 71.246 |
| List pipeline | 48.786 | 48.921 | 348.484 | 19.579 | 19.756 |

Branch/call CPU improves **8.7%** and Fibonacci **16.4%**. Their native images shrink
851→795 and 618→561 bytes. Recurrence and list images are unchanged, with CPU medians
within 0.5%; their differing wall times illustrate why image identity and CPU/wall
must be reported separately. GCC remains ahead on the four longer workloads, and
Node remains ahead on branch/call in this cohort. These are bounded improvements,
not a claim of general parity.

The compiler passes **763 tests**, **394 upstream comparisons**, and two
byte-identical native self-rebuilds. New cases check all six comparisons, reversed
arm order, operand side effects, unselected overflow, local scope and tail re-entry.
An actual disassembly test verifies the direct condition consumes flags without a
`setl`/Boolean-store/reload sequence.

[All paired samples](evidence/comparison-flags-surface-baselines.json),
[qualification](evidence/comparison-flags-qualification.json),
[native rebuilds](evidence/comparison-flags-native-rebuilds.json).

Repeat with retained native images:

```sh
python3 tools/benchmark_surface.py NEW_NATIVE_COMPILER out/paired-results.json \
  --native-baseline PREVIOUS_NATIVE_COMPILER
```

The first baseline table above deliberately retains its original 647,417-byte
compiler and observed measurements. This follow-up does not rewrite that history.
