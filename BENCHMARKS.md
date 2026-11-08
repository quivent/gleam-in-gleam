# Native compiler benchmark protocol

Finish and qualify the current allocation pass before running timing comparisons.
Compiler logic remains Gleam, with zero third-party compiler/runtime dependencies.

The pass represents scalar comparisons, short-circuit Boolean control flow and
supported two-arm Boolean/Int-literal cases as real branches/joins. Liveness takes
the union of successor live-ins and reaches a fixed point for backedges. General
pattern bindings/guards, data-valued cases and indirect/non-scalar call regions
retain their existing lowering; this is not a claim of full upstream compatibility
or whole-function allocation across every language construct.

## Method

`tools/benchmark_native.py` freezes identical source bytes from the previous
qualified source revision, runs one warm-up per version, then five measured
repeats in alternating order. The owned child is pinned to the same CPU. Wall
clock includes fork/exec and wait; CPU/RSS come from wait4. No caches are globally
dropped, no governor is changed and no unrelated process is stopped. Small-program
RSS includes pre-exec setup and must be treated as an upper bound.

Measurements separate:

* Full native compilation of the identical frozen compiler source, including
  deterministic output checks and execution of the produced compiler/probe.
* Generated-code runtime for arithmetic, branch joins, short-circuit calls and
  values live across calls. Exact checksums are independently calculated.
* Image size, compile CPU/wall time and maximum RSS, reported separately.

The host is shared. Report all samples, median, min/max and host load; do not infer
a language-wide ranking or general speedup from these workloads. Different backend
versions may emit different compiler images from the same source. Qualify behavior
and reproducibility rather than requiring cross-version image identity.

The main correctness corpus, native self-rebuilds, seeded arithmetic/call/branch
oracles and benchmark inputs/outputs must be tied to exact source/image hashes.
Benchmarks do not replace correctness checks. The qualified results follow.

## Qualified results — 2026-11-08

Candidate: 637,999-byte compiler, SHA256
`3a8063b7582cb04e53c7443110403dc80f7c757fab0a893add0089a367ca8b65`.
Baseline: 617,676 bytes, SHA256
`38eaaeb14bd30e616378134367ed0fe4fdebc6c19868c4cd30de18fd69b4258e`.
729 tests, 371 independent upstream comparisons, all 371 rebuilt-native cases and
two exact self-rebuilds pass. Three separately reported 100-expression programs
qualify pure arithmetic, calls/effects and nested branches. Those programs are
not counted as 300 additional independent compilation cases.

Host: Intel Xeon Processor (Icelake), Linux, shared; child affinity pinned to one
allowed CPU. Five measured runs per version after one warm-up, alternating order.
See raw receipts for exact kernel, affinity, load, source, harness and image hashes.

### Actual current-source compilation

Both versions compile identical current compiler source at `7fc27b6`; its full
source hash map equals the qualification snapshot. The candidate output is byte-
identical to its own input executable. All repeats are deterministic. Produced
compilers run --version and compile/execute a checked probe; its bytes agree.

| Measure | Baseline | Candidate |
| --- | ---: | ---: |
| Median elapsed | 9.061 s | 8.751 s |
| Median CPU | 7.494 s | 7.419 s |
| Elapsed min–max | 8.408–10.943 s | 8.354–9.774 s |
| Maximum RSS | 386.9 MiB | 390.8 MiB |

The candidate median elapsed is 3.4% lower and CPU about 1% lower, but distributions
overlap. Peak RSS rises about 3.9 MiB. This does not establish a broad compile-time
speedup. An older frozen-source cohort is also retained separately; do not confuse
its build time with compiling the new compiler's own source.

### Generated-code runtime

Longer trials use 40,000,000 iterations with independently calculated exact
checksums. CPU time helps separate execution from scheduler/launch delays.

| Workload | Baseline median CPU | Candidate median CPU | Observed CPU change |
| --- | ---: | ---: | ---: |
| arithmetic | 300.94 ms | 300.80 ms | -0.05% |
| branch-join | 383.86 ms | 375.87 ms | -2.08% |
| short-circuit-call | 461.96 ms | 477.67 ms | +3.40% |
| live-across-call | 468.39 ms | 466.62 ms | -0.38% |

Branch-join output shrinks 668→623 bytes (45 bytes); short-circuit-call output
756→727 bytes (29 bytes). Arithmetic and live-across-call controls are byte-
identical between versions. Even those identical programs have differing elapsed
medians on this host, so elapsed differences must not be advertised as code wins.
Branch CPU is about 2% lower here; short-circuit CPU is about 3% higher despite
its smaller image. There is no conclusive general runtime speedup.

The first 4,000,000-iteration trial is retained: short timings were especially
sensitive to launch/scheduler effects, prompting the longer trial. Runtime RSS
includes fork/pre-exec setup and is not presented as target-only memory use.

### Evidence and repeat

* [Current-source self-build samples](evidence/control-flow-self-build-benchmarks.json)
* [Longer runtime and older-source compilation samples](evidence/control-flow-benchmarks-long.json)
* [Initial shorter trial](evidence/control-flow-benchmarks.json)
* [Correctness qualification](evidence/control-flow-qualification.json)
* [Native rebuilds](evidence/control-flow-native-rebuilds.json)
* [Branch oracle](evidence/control-flow-seeded-branches.json)

```sh
python3 tools/benchmark_native.py BASELINE_COMPILER CANDIDATE_COMPILER out/performance.json --repetitions 5 --iterations 40000000
python3 tools/benchmark_native.py BASELINE_COMPILER CANDIDATE_COMPILER out/self-build-performance.json --source-revision 7fc27b6 --compile-only --expect-candidate-image --repetitions 5
```

Use exact recorded native images. The second command's self-image expectation is
valid only when the candidate was built from that exact source snapshot. Benchmark
outputs are created in an owned temporary directory and removed afterward; no
installed compiler, active crew session, system cache or governor is changed.

## Memory interpretation

The 390.8 MiB number is peak resident working memory during self-compilation,
not the compiler file size (637,999 bytes) or a requirement imposed on generated
programs. The compiler reserves a bounded 512 MiB arena. Its bump allocator has
no collection or phase reclamation, so discarded intermediates also consume arena
space until process exit. Allocation volume must be profiled before attributing
most of that memory to a particular phase. Reduce unnecessary temporary lists,
copies and buffers before choosing whether collection is warranted. Large memory
use alone does not establish slow execution; the timing results are separate.


## Byte-count allocation rewrite — 2026-11-08

The later structural byte-count rewrite has a separate controlled experiment:
both versions compile the same 27-module source at `7fc27b6`, one warm-up and five
alternating repeats, CPU-pinned. Median CPU falls **7.522 → 5.015 s (33.3%)**;
median wall falls **8.586 → 5.883 s (31.5%)**, with ranges 8.393–8.916 and
5.123–6.913 s respectively. Peak RSS falls **390.8 → 323.6 MiB**. The shared-host
wall variation remains visible; no general language ranking follows.

The candidate is 644,591 bytes, including its recognizer. On fixed input its
output is 637,775 bytes vs 637,999 before. Current 28-module self-rebuilds remain
byte-identical to the candidate. See [all samples](evidence/byte-count-benchmark.json)
and [phase allocation analysis](MEMORY.md). Earlier measurements above are retained
as historical results, not overwritten with this later improvement.

## Direct lookup and retained parse — 2026-11-08

These changes primarily reduce memory use. Two independent repeated comparisons
use the same frozen `7fc27b6` compiler input and the preceding byte-count compiler
as baseline. Five alternating repeats follow one warm-up per variant; host variation
is preserved rather than turning allocation savings into a predicted speedup.

| Comparison | Baseline CPU median | Candidate CPU median | Baseline wall median | Candidate wall median |
|---|---:|---:|---:|---:|
| Direct lookup only | 5.016 s | 4.867 s | 6.233 s | 5.720 s |
| Lookup + retained parse | 4.833 s | 4.730 s | 5.102 s | 5.150 s |

The final combined comparison uses about **2.1% less CPU time**, while median wall
time is about **0.9% higher**. That is not a convincing broad wall-speed improvement.
The memory result is much stronger: final untraced maximum RSS is **224,128 KiB**
(218.9 MiB), vs **331,392 KiB** (323.6 MiB) for that run's baseline. Trace-derived
RSS is slightly different (218.5 MiB); retain both as observations of different runs.
Allocation falls 338,729,536 → 228,947,576 bytes in the separate cursor traces.

Lookup-only wall ranges are 5.654–7.290 s baseline and 5.463–9.568 s candidate;
final ranges are 4.741–5.411 s baseline and 5.125–5.250 s candidate. Do not compare
medians from the two different runs as though they were controlled against each
other. The baseline itself varies. Both frontend candidates emit the exact same
frozen-target compiler hash as the preceding byte-count backend.

[Lookup-only samples](evidence/lookup-search-benchmark.json),
[combined samples](evidence/parsed-snapshot-benchmark.json),
[allocation evidence](evidence/parsed-snapshot-allocation-reduction.json).
