<h1 align="center">Gleam in Gleam</h1>

```text
  ____ _     _____    _    __  __
 / ___| |   | ____|  / \  |  \/  |
| |  _| |   |  _|   / _ \ | |\/| |
| |_| | |___| |___ / ___ \| |  | |
 \____|_____|_____/_/   \_\_|  |_|

          I N   G L E A M

 source -> compiler -> machine code
```

<p align="center">
  <img src="docs/assets/language.svg" alt="Compiler source: Gleam">
  <img src="docs/assets/target.svg" alt="Native target: Linux x86-64">
  <img src="docs/assets/dependencies.svg" alt="Third-party compiler/runtime dependencies: zero">
  <br>
  <img src="docs/assets/checks.svg" alt="Qualified regression checks: 763 of 763">
  <img src="docs/assets/rebuilds.svg" alt="Two native rebuilds are byte-identical to the seed">
</p>

<p align="center"><strong>A compiler written in the language it compiles.<br>Its own machine-code backend. Its own runtime. A native self-rebuild.</strong></p>

## Index

[01 · Overview](#01--overview) · [02 · Language](#02--language) · [03 · Quick start](#03--quick-start)<br>
[04 · Native bootstrap](#04--native-bootstrap) · [05 · Architecture](#05--architecture) · [06 · Machine code](#06--machine-code)<br>
[07 · Memory & performance](#07--memory--performance) · [08 · Verification](#08--verification) · [09 · Boundaries](#09--boundaries)<br>
[10 · Roadmap](#10--roadmap) · [11 · Reading room](#11--reading-room) · [12 · Development](#12--development)

---

## 01 · Overview

Gleam in Gleam is a self-hosting compiler for a supported subset of Gleam. All
compiler logic lives in **28 Gleam modules**: from source bytes and type checking
to instruction selection, relocation and ELF writing.

The result is a standalone **Linux x86-64 compiler**. It reads Gleam, emits native
executables, and recompiles its own complete supported source. Two successive
native rebuilds are byte-identical to the seed.

| Verified snapshot · 2026-11-08 | Result |
|:---|---:|
| Standalone compiler image | **653,202 bytes** |
| Regression tests | **763 / 763 passed** |
| Independent upstream comparisons | **394 cases** |
| Native self-rebuilds | **2, both byte-identical to the seed** |
| Third-party compiler/runtime dependencies | **0** |
| Same-input peak RSS, instruction-span milestone | **168.5 MiB** |

> [!IMPORTANT]
> **Self-hosting is verified within the supported subset.** Full upstream Gleam
> compatibility, additional targets and further optimization remain open.
> [Exact source hashes, images and outcomes →](SELF_HOSTING.md)

There is no LLVM, Cranelift, external assembler, external linker, libc, bundled VM
or standard-library package in the delivered native compiler. Existing Gleam and
Node are used for the initial development bootstrap; the native compiler runs
without them afterward.

[Back to index ↑](#index)

---

## 02 · Language

The source language is **Gleam**, with an explicit implementation boundary. Typed
functions, immutable values and pattern matching carry through to owned native
code generation.

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

**Output:** `15`.

| Aspect | Implemented scope |
|:---|:---|
| Values & expressions | Int, Bool, Nil, String, BitArray, checked arithmetic, comparisons, short-circuit booleans |
| Data | Tuples, lists, spreads, recursive and generic nominal custom types |
| Functions | Named/recursive calls, function values, captured closures, captures and `use` callbacks |
| Patterns | Nested constructors/lists/tuples, aliases, multiple subjects, alternatives, supported guards and coverage checks |
| Records | Labelled constructors, field access, immutable updates and checked generic constraints |
| Modules | Rooted local imports, aliases, visibility, nominal identities, dependency order and cycle rejection |
| Types | Explicit function signatures, supported contextual inference, generic custom types and transparent aliases |
| Strings & bytes | UTF-8 strings, concatenation, byte equality, literal/prefix patterns and supported byte-aligned segments |
| Prelude | Implicit `Result(a, e)`, `Ok` and `Error` |

These capabilities have individual limits: contextual inference is not general
inference, supported equality is not arbitrary erased-value equality, and the
BitArray subset does not include dynamic or unaligned segments.

<details>
<summary><strong>Example: labelled data and immutable updates</strong></summary>

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

**Output:** `14`, then `8`. The original remains immutable.

</details>

<details>
<summary><strong>Example: callbacks with <code>use</code></strong></summary>

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

**Output:** `6`. The callback uses the same owned closure representation as function
values; it does not require an external runtime.

</details>

[Full syntax, semantics, examples and compiler API →](GUIDE.md#2-language-syntax-and-semantics)

[Back to index ↑](#index)

---

## 03 · Quick start

**Bootstrap prerequisites:** Gleam 1.19.2, Node 22+, and Linux x86-64 to run the
native outputs. No package download is required by the project manifests.

```sh
git clone git@github.com:quivent/gleam-in-gleam.git
cd gleam-in-gleam

gleam build --warnings-as-errors
mkdir -p out
node build-native.mjs out/gleam-native

./out/gleam-native fibonacci.gleam out/fibonacci --source-root examples
./out/fibonacci
# 55
```

After the initial build, use the native compiler directly:

```text
gleam-native SOURCE.gleam NEW_OUTPUT [--source-root DIRECTORY]
gleam-native --build-compiler NEW_OUTPUT [--source-root DIRECTORY]
gleam-native --help
gleam-native --version
```

> [!TIP]
> **Choose new output paths.** Publication refuses to overwrite existing files,
> directories or symlinks. Native SOURCE paths are relative to `--source-root`,
> which defaults to the current directory.

Compile the multi-module example with the same compiler:

```sh
./out/gleam-native modules.gleam out/modules --source-root examples
./out/modules
# 14
# 8
# 3
```

The development bootstrap also remains available:

```sh
node bootstrap.mjs examples/fibonacci.gleam out/bootstrap-fibonacci
```

Its default source root is the input file's directory; the native CLI instead uses
the current directory. [Complete CLI and IO contract →](NATIVE_CLI_SPEC.md)

[Back to index ↑](#index)

---

## 04 · Native bootstrap

```text
   ONE-TIME DEVELOPMENT BOOTSTRAP
   ------------------------------
   Our Gleam source
          |
          v
   Existing Gleam compiler -> JavaScript + Node IO bridge
                                      |
                                      v
                              Native compiler seed

   NATIVE SELF-HOSTING
   ------------------
   Gleam source -> native seed -> native stage 2 -> native stage 3
                     |                  |                  |
                     +------ identical executable bytes ---+
```

The native stages parse and compile the source. They do not invoke upstream Gleam,
run Node, copy their own executable, or embed a VM. A separate changed-source
control produces the expected changed compiler image, verifying that the rebuild
actually consumes source.

Repeat with unchanged input and fresh output paths:

```sh
./out/gleam-native --build-compiler out/stage2 --source-root src
./out/stage2 --build-compiler out/stage3 --source-root src
cmp out/gleam-native out/stage2
cmp out/stage2 out/stage3
```

<details>
<summary><strong>Exact qualified native image</strong></summary>

**653,202 bytes**, with no dynamic loader or dynamic libraries and a non-executable
stack. The seed and both native rebuilds have SHA256:

```text
1068e2110485d9e37a3e479fb87a0d5f9ace8c3aca0bf9ecd3194cff3468056c
```

The stage-3 compiler also passes all **394 positive/negative corpus cases**.
Accepted output matches bootstrap executable bytes and runs correctly; rejected
input fails without publishing an executable.

[Native rebuild receipt →](evidence/comparison-flags-native-rebuilds.json)

</details>

[Back to index ↑](#index)

---

## 05 · Architecture

```text
   Source bytes
        |
        v
   UTF-8 validation -> Lexer -> Parser -> immutable AST
                                             |
                             Local imports + resolution
                                             |
                                Definitions + type checks
                                             |
                                        Typed program
                                             |
                          x86-64 lowering + scalar allocation
                                             |
                                Instruction parts + labels
                                             |
                                Owned assembler + ELF writer
                                             |
                                      Native executable
```

| Layer | Owned Gleam modules |
|:---|:---|
| Front end | [`ast`](src/native/ast.gleam), [`lexer`](src/native/lexer.gleam), [`parser`](src/native/parser.gleam), [`utf8`](src/native/utf8.gleam) |
| Resolution & types | [`project`](src/native/project.gleam), [`definitions`](src/native/definitions.gleam), [`check`](src/native/check.gleam), [`type_system`](src/native/type_system.gleam), [`prelude`](src/native/prelude.gleam) |
| Language support | [`coverage`](src/native/coverage.gleam), [`labels`](src/native/labels.gleam), [`free_names`](src/native/free_names.gleam), [`bit_options`](src/native/bit_options.gleam) |
| Machine code | [`x64`](src/native/x64.gleam), [`registers`](src/native/registers.gleam), [`loop_idioms`](src/native/loop_idioms.gleam), [`assembler`](src/native/assembler.gleam), [`elf`](src/native/elf.gleam) |
| Values & memory | [`heap`](src/native/heap.gleam), [`string_runtime`](src/native/string_runtime.gleam), [`equality`](src/native/equality.gleam), [`equality_runtime`](src/native/equality_runtime.gleam), [`core`](src/native/core.gleam) |
| Entry & IO | [`compiler`](src/native/compiler.gleam), [`cli`](src/native/cli.gleam), [`cli_builder`](src/native/cli_builder.gleam), [`cli_runtime`](src/native/cli_runtime.gleam), [`cli_limits`](src/native/cli_limits.gleam) |

The loader keeps original source bytes and their parsed module in one immutable
snapshot. Dependency discovery and linking reuse that AST. Existing raw-source
API callers still work; unreachable supplied raw source remains unparsed.

[Detailed architecture, lifetimes and APIs →](GUIDE.md#3-architecture-source-to-executable)

[Back to index ↑](#index)

---

## 06 · Machine code

The backend emits **x86-64 instruction bytes directly**. Its assembler resolves
labels and relative displacements; its ELF writer creates the executable image.
Assembly listings are inspection evidence, not an external compilation step.

| Work already implemented | What it does |
|:---|:---|
| Direct self-tail calls | Replace parameters and loop after the prologue in supported returned blocks/cases |
| Operand look-ahead | Retain safe leaf operands in registers while preserving effects and call spills |
| Sibling-arm slot reuse | Reserve the maximum mutually exclusive branch footprint |
| Scalar register allocation | Track values, flags, clobbers and real spills across supported scalar regions |
| Call preservation | Save live values before arguments; preserve returns before restoring caller values |
| Direct comparison cases | Consume integer comparison flags without storing/retesting an intermediate Boolean |
| Scalar CFG joins | Use successor-aware liveness for supported comparisons, short circuits and cases |
| Structural byte-count recognition | Replace an exact pure unit-step loop with a length load and checked addition |

General data/guarded patterns and indirect/non-scalar calls still have lowering
boundaries. This is not a whole-function allocator for every Gleam construct.

The runtime owns its layouts and memory arena. Function values contain code
pointers and copied captures; byte-array tails retain payload ownership. R14/R15
remain reserved arena registers. There is **no GC or arena growth yet**.

[ASM and runtime layouts →](ASM.md) · [Register allocation specification →](REGISTER_SPILL_SPEC.md)

[Back to index ↑](#index)

---

## 07 · Memory & performance

<!-- GTA_BENCHMARK_LEDGER_START -->
### GTA via Gleam — living benchmark ledger

**Self-hosted native compiler · last measured 2026-11-08 · 763 regression checks passed.**

Frozen native baseline: `9f5bb10` (647,417 B). Current measured code: `fa468e6` (653,202 B).
Baseline changes must be explicit; the ledger retains each qualified cohort and exact image hash.

**Generated-program runtime.** Median CPU milliseconds; positive percentages reduce cost. `≈` marks changes under 1%, not a statistical confidence claim.

| Workload | Previous native CPU | GTA CPU | CPU reduction | Wall reduction | Target-size reduction |
|:---|---:|---:|---:|---:|---:|
| Startup control | 0.362 ms | 0.354 ms | ↑ +2.21% | ↑ +6.12% | ≈ +0.00% |
| Integer recurrence · 20M | 322.359 ms | 323.890 ms | ≈ -0.47% | ↓ -1.21% | ≈ +0.00% |
| Branch + call · 20M | 327.907 ms | 299.503 ms | ↑ +8.66% | ↑ +8.26% | ↑ +6.58% |
| Fibonacci · n=35 | 232.507 ms | 194.260 ms | ↑ +16.45% | ↑ +9.26% | ↑ +9.22% |
| List build/map/sum · 500K | 48.786 ms | 48.921 ms | ≈ -0.28% | ↑ +24.12% | ≈ +0.00% |

**Suite CPU:** 1.068× the baseline throughput, or **+6.36% less CPU** (geometric mean of the four longer workload ratios; startup excluded). This summary does not replace the per-workload regressions/controls above.

**Earlier hosting architecture versus self-hosting.** The same qualified compiler logic runs under the Node bootstrap and as native GTA. These are compilation measurements, including startup; output ELF bytes and results match. This is not an older source revision.

| Compile workload | Node-hosted CPU | Self-hosted GTA CPU | CPU reduction | Wall reduction | Peak-RSS reduction |
|:---|---:|---:|---:|---:|---:|
| Startup control | 176.004 ms | 0.907 ms | ↑ +99.48% | ↑ +98.12% | ↑ +98.90% |
| Integer recurrence · 20M | 203.348 ms | 1.234 ms | ↑ +99.39% | ↑ +98.64% | ↑ +98.70% |
| Branch + call · 20M | 200.348 ms | 1.362 ms | ↑ +99.32% | ↑ +97.58% | ↑ +98.71% |
| Fibonacci · n=35 | 179.345 ms | 1.040 ms | ↑ +99.42% | ↑ +97.89% | ↑ +98.69% |
| List build/map/sum · 500K | 208.836 ms | 1.249 ms | ↑ +99.40% | ↑ +97.82% | ↑ +98.52% |

Tiny-input hosting gains are dominated by launch/module initialization. They do not establish whole-project compilation speedups.

**Compiler self-build optimization history.** Each row is its own paired experiment on frozen source; percentages are not chained across different runs.

| Experiment | CPU before → after | CPU reduction | Wall reduction | Peak-RSS reduction |
|:---|---:|---:|---:|---:|
| Byte-count rewrite | 7.522 → 5.015 s | ↑ +33.34% | ↑ +31.48% | ↑ +17.18% |
| Direct lookup | 5.016 → 4.867 s | ↑ +2.96% | ↑ +8.24% | ↑ +14.72% |
| Lookup + retained AST | 4.833 → 4.730 s | ↑ +2.13% | ≈ -0.94% | ↑ +32.37% |
| Instruction spans | 4.816 → 5.213 s | ↓ -8.24% | ↓ -8.10% | ↑ +22.96% |

**External references — same runtime cohort.** CPU ratios below 1× favor GTA; above 1× favor the reference. These compare supported workloads, not complete language implementations.

| Workload | GTA / upstream Gleam-Node CPU | GTA / GCC O2 CPU | GTA / GCC O3 CPU |
|:---|---:|---:|---:|
| Startup control | 0.006× | 0.328× | 0.311× |
| Integer recurrence · 20M | 0.556× | 2.106× | 2.109× |
| Branch + call · 20M | 1.599× | 4.688× | 4.664× |
| Fibonacci · n=35 | 0.393× | 2.555× | 2.727× |
| List build/map/sum · 500K | 0.140× | 2.499× | 2.476× |

Every runtime/compile table uses five measured repeats after a warm-up; CPU affinity is pinned, source/results are checked, and fresh processes include startup. Shared-host noise and allocator/runtime differences remain material. The regression count is correctness evidence, not another benchmark score.

[Raw paired samples](evidence/comparison-flags-surface-baselines.json) · [Hosting samples](evidence/bootstrap-hosting-baseline.json) · [Full interpretation](PERFORMANCE.md) · [Ledger configuration](benchmarks/ledger.json)

Regenerate with `python3 tools/render_benchmark_ledger.py`; `--check` rejects stale README figures. Append a qualified cohort and rerun against the frozen native image to track the next optimization.

<!-- GTA_BENCHMARK_LEDGER_END -->

### Remove unnecessary allocation before adding collection

Every stage below rebuilds the **same frozen 27-module input**. Allocation traces
and output hashes are retained; the input is deliberately fixed as the compiler
evolves.

| Compiler stage | Allocated volume | Peak RSS in trace |
|:---|---:|---:|
| Before byte-count optimization | 409.2 MB | 390.8 MiB |
| Pure byte-count rewrite | 338.7 MB | 323.6 MiB |
| Direct lookup over existing lists | 288.9 MB | 275.9 MiB |
| Retain and reuse parsed modules | 228.9 MB | 218.5 MiB |
| Share immutable instruction spans | **176.3 MB** | **168.5 MiB** |

**56.9% fewer allocated bytes**, without a collector or new dependency. These are
allocation volumes and observed resident memory—not measurements of reachable
live objects or the arena's reserved capacity.

### Generated-program progress

A paired before/after run of direct comparison-flag lowering reduces branch/call
CPU time **328 → 300 ms** and recursive Fibonacci **233 → 194 ms**. Unchanged
recurrence/list controls remain within 0.5% CPU variation. GCC still leads the
longer workloads; Node still leads branch/call in that cohort.
[Checked external comparisons and actual ASM →](PERFORMANCE.md)

### Timing gets its own evidence

| Separate controlled experiment | Median CPU before → after | Median wall before → after |
|:---|---:|---:|
| Byte-count rewrite | 7.522 → 5.015 s | 8.586 → 5.883 s |
| Lookup + retained parse, versus byte-count baseline | 4.833 → 4.730 s | 5.102 → 5.150 s |

Each comparison has one warm-up per variant and five alternating measured repeats
on a pinned CPU. The shared host varies: compare pairs within a row, not measurements
from different runs. The frontend changes give a substantial memory reduction;
their final wall-time result is effectively flat. Smaller images and fewer
allocations do not automatically make generated programs execute faster.

> [!NOTE]
> **Compiler performance and generated-program performance are separate.**
> These rebuild measurements describe compiling a fixed input. They do not rank
> Gleam against other languages or establish a universal runtime speedup.

The current native compiler is **653,202 bytes**. Working RAM, reserved arena size,
and executable size are separate quantities.

[Allocation investigation →](MEMORY.md) · [All timing samples and methodology →](BENCHMARKS.md) · [External native/Node/GCC baselines →](PERFORMANCE.md)

[Back to index ↑](#index)

---

## 08 · Verification

```text
   763 / 763    regression tests passed
   394          independent upstream comparisons
   394          cases through the rebuilt native compiler
    16          native example programs
    59          CLI-specific checks
     9          complete guide examples compiled and executed
     2          native self-rebuilds identical to the seed
```

These categories overlap; they are **not** added together into a larger test count.
The guide examples have a separate execution receipt. Static badges at the top
summarize this qualified snapshot, rather than claiming a live CI service.

Verification includes accepted/rejected language cases, effects and evaluation
order, overflow, closures and captures, alias/visibility rules, deterministic
output, rooted IO, short/interrupted IO, destination preservation, ELF headers,
and changed-source/native self-hosting controls.

| Evidence | Record |
|:---|:---|
| Full qualification | [Source hashes, tests and outcomes](evidence/comparison-flags-qualification.json) |
| Native self-hosting | [Stages, image hashes and corpus](evidence/comparison-flags-native-rebuilds.json) |
| Native CLI | [IO, fault injection and ELF checks](evidence/comparison-flags-io-verification.json) |
| Memory | [Same-input allocation comparison](evidence/parsed-snapshot-allocation-reduction.json) |
| Timing | [Repeated CPU, wall and RSS measurements](evidence/parsed-snapshot-benchmark.json) |
| Language guide | [Nine actual native executions](evidence/comparison-flags-guide-execution.json) |

Upstream Gleam is an independent development oracle. The native compiler does not
invoke it during compilation. Initial failures and earlier milestones remain in
the repository under their original evidence filenames.

[Back to index ↑](#index)

---

## 09 · Boundaries

| Area | Current boundary |
|:---|:---|
| Target | Linux x86-64 ELF; no ARM64 or Mach-O output yet |
| Source graph | 128 KiB per source file; at most 256 files |
| Compiler arena | 512 MiB reserved, bounded, without GC or growth |
| Ordinary program arena | 64 MiB for allocated compound values |
| Integers | Checked signed 64-bit operations; source literal magnitude limited to 2^53−1 |
| Inference & calls | Explicit top-level signatures; bounded contextual inference; no ordinary labelled calls or polymorphic named function values |
| Language coverage | No constants, attributes, opaque/empty custom types, Float or UtfCodepoint yet |
| Imports & tooling | Local rooted modules; no package resolution, selective imports, formatter or language server |
| Values | Erased generic/function equality and general compound printing remain unsupported |
| Recursion | Direct returned self-calls optimized; mutual/indirect calls remain ordinary calls; deep non-tail syntax can exhaust stack |
| Diagnostic printing | Primitive `echo` output convention; not full upstream debug-format compatibility |

Unsupported forms must produce explicit diagnostics. Existing supported features
also have detailed limits, including coverage shapes, byte segments and guards.

[Full compatibility boundary and semantics →](GUIDE.md#compatibility-boundary-checklist)

[Back to index ↑](#index)

---

## 10 · Roadmap

```text
   SUPPORTED-SUBSET SELF-HOSTING
   [####################] 100% of its defined acceptance scope
```

| Workstream | State |
|:---|:---|
| Native CLI and owned IO runtime | Verified within stated bounds |
| Full-size supported compiler input | Qualified |
| Independent language comparisons | Qualified corpus, expanding with features |
| Successive native self-rebuilds | Byte-identical |
| Broader Gleam compatibility | Open |
| Remaining value semantics | Open |
| Measured optimization | In progress; current increment qualified |
| Additional targets and distribution | Open |

Code planning now shares immutable instruction spans: its allocation falls from
**83.0 to 28.8 MB** on the frozen input, preserving identical emitted target bytes.
Generated-program runtime optimization remains a separate dimension.

[Roadmap and remaining work →](ROADMAP.md) · [Interactive eight-step roadmap →](docs/roadmap.html)

The interactive page is portable, offline documentation with expandable specs,
evidence links, search and local notes. Open the checkout HTML in a browser;
GitHub displays its source. [Preview instructions →](docs/README.md)

[Back to index ↑](#index)

---

## 11 · Reading room

| Read this | For |
|:---|:---|
| [Implementation & language guide](GUIDE.md) | Syntax, complete examples, usage, architecture, runtime, API and limitations |
| [Self-hosting proof](SELF_HOSTING.md) | Exact native chain, image hashes and acceptance scope |
| [Native CLI specification](NATIVE_CLI_SPEC.md) | Commands, rooted IO, failure handling and explicit limits |
| [ASM reference](ASM.md) | Native layouts, calling conventions and emitted instructions |
| [Register allocation specification](REGISTER_SPILL_SPEC.md) | Liveness, register pressure, clobbers, spills and remaining boundaries |
| [Memory investigation](MEMORY.md) | Phase traces, lookup/AST changes, allocation savings and caveats |
| [External performance baselines](PERFORMANCE.md) | Checked native / Gleam-Node / GCC O2-O3 comparisons |
| [Benchmark record](BENCHMARKS.md) | Repeated measurements, environment, raw samples and interpretation |
| [Implementation journal](JOURNEY.md) | Decisions, discoveries, tradeoffs and the sequence of changes |
| [Reliability record](FULL_SIZE_RELIABILITY_SPEC.md) | Initial full-size failures, investigation and bounded fixes |
| [Earlier working README](IMPLEMENTATION_HISTORY.md) | Preserved detailed feature notes and milestone history |
| [Roadmap](ROADMAP.md) | Remaining language, value, optimization and target work |

[Back to index ↑](#index)

---

## 12 · Development

Run full qualification from the checkout:

```sh
python3 verify.py
```

This requires development/bootstrap and inspection tools: Gleam, Node, Python,
objdump, strace and ptrace permission. They are **development tools**, not native
compiler/runtime dependencies. Run the guide examples separately against a selected
native compiler:

```sh
python3 tools/verify_guide.py out/gleam-native out/guide-receipt.json
```

Compiler changes stay in Gleam. Preserve unsupported-feature diagnostics, independent
oracle comparisons, immutable source snapshots, existing artifacts and active
sessions. Keep semantic changes separable, retain failures, inspect actual ASM,
and measure CPU, wall time, allocation, RSS and image size independently.

<p align="center"><strong>Source in Gleam. Native output. Evidence at every stage.</strong></p>

[Back to index ↑](#index)
