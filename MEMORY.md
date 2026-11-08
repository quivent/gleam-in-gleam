# Allocation before collection

The first memory optimization removes unnecessary allocations instead of adding
GC. It is implemented in Gleam, with no new native runtime dependency.

## Controlled result

Both compilers rebuilt the **same 27-module input frozen at `7fc27b6`**. The
candidate includes the new recognizer; the input remains the earlier compiler.
Each output is checked against its corresponding bootstrap reference. Their
output hashes differ legitimately because code generation changed. This experiment
is separate from current-source self-hosting, where all three images are identical.

| Measurement | Before | After |
|---|---:|---:|
| Arena allocation volume | 409,183,952 B | 338,729,536 B |
| Peak resident memory | 400,128 KiB | 331,392 KiB |
| Peak resident memory in MiB | 390.8 | 323.6 |
| Emitted compiler for frozen input | 637,999 B | 637,775 B |

That saves **70,454,416 allocated bytes (17.2%)** and **67.1 MiB peak RSS**.
The candidate compiler itself is 644,591 bytes because it contains the new
recognizer. A smaller generated image does not establish faster execution.

[Before trace](evidence/allocation-phases-before.json),
[after trace](evidence/allocation-phases-after.json),
[controlled comparison](evidence/byte-count-allocation-reduction.json).

## Repeated untraced timing

Five alternating measured runs per compiler, after one warm-up each, pinned to
one CPU on this shared Icelake host:

| Same frozen input | Before | After |
|---|---:|---:|
| Median CPU seconds | 7.522 | 5.015 |
| Median wall seconds | 8.586 | 5.883 |
| Wall min–max seconds | 8.393–8.916 | 5.123–6.913 |

CPU time falls **33.3%** and median wall time falls **31.5%** in this workload.
The candidate's wall variation is substantial; this is not a language-wide speed
claim or an upstream compiler comparison. All outputs are deterministic and their
produced compilers execute the benchmark probe correctly.
[All samples and environment](evidence/byte-count-benchmark.json).

## Finding the waste

The development profiler starts a new owned compiler child and uses Linux ptrace
breakpoints at selected function entries/returns to inspect the R15 arena cursor.
It does not alter compiler source, attach to existing sessions, or modify installed
tools. Inclusive allocations include callees; do not sum nested rows.

| Phase (inclusive) | Before bytes | After bytes |
|---|---:|---:|
| Project linking | 121,725,864 | 121,725,864 |
| Type checking | 41,866,200 | 41,866,200 |
| Code planning | 83,486,864 | 82,964,584 |
| Assembly | 74,629,720 | 30,210,408 |
| ELF packaging | 26,151,312 | 638,168 |

ELF packaging was particularly revealing: counting about 638 KB of code allocated
about 25.5 MB of suffix views. Each iteration discarded one byte and constructed a
new tail descriptor. The payload was shared, but the descriptors accumulated in
the bump arena. Assembly had the same generic counting cost repeatedly.

Allocation volume is **not reachable live data**. Peak RSS measures resident pages;
it is distinct from reserved arena capacity. Tracing timings are not performance
measurements. Repeated untraced timings are recorded separately below.

## Exact structural rewrite and ASM

The recognizer accepts a typed, effect-free two-argument function returning Int:
a case on BitArray, discarded one-byte head and complete tail, direct self-call
with `counter + 1`, then an unguarded fallback returning the unchanged counter.
Parameter order may differ. It does not recognize functions by name.

The replacement loads the descriptor's existing byte length at offset 16, adds the
initial counter and branches to the existing signed-overflow trap. The resulting
function is 40 bytes including its prologue/epilogue, instead of 264 bytes. Actual
objdump inspection checks the length load, addition and overflow branch, with no
loop or allocation call. Immutable aliases and borrowed tails retain their lengths.

Changed increment/base, effects, guards, shadowed counter and different callees
are rejected by the recognizer and use ordinary lowering. Tests cover these cases,
function descriptor calls, signed overflow, aliases and a 4 MiB count within the
ordinary 64 MiB arena. The rewrite relies on the existing byte-aligned BitArray
contract; it does not add support for unaligned bit arrays.

## Correctness and reproduction

The source revision is `5844aec`. [Qualification](evidence/byte-count-qualification.json)
passes **744 tests** and **383 independent upstream comparisons**. The rebuilt
native stage-3 compiler passes all 383 positive/negative cases. The seed and two
native rebuilds are each 644,591 bytes, SHA256
`47999bf4831281341ad5e2d8ca15e49663d67fe5304a302ca6c44f6685995c7f`.
Full upstream Gleam compatibility remains incomplete.

Development-only phase tracing requires Linux ptrace access and Python:

```sh
node tools/native_debug_build.mjs WORKING 131072 out/profile 536870912
python3 tools/profile_native_allocations.py out/profile/symbols.json \
  out/profile/receipt.json out/profile/compiler out/profile/source-snapshot/src \
  out/profile/rebuilt
```

Use new output paths. For cross-version fixed-input comparisons, supply the
independently generated target hash with `--expected-output-sha`; otherwise the
profiler requires a byte-identical self-rebuild.

## Next measured target

Linking now allocates the most among these selected phases: about 122 MB. Profile
its parser/linker subphases before changing representations. Initial source intake,
code planning and checking also remain substantial. Definitions are collected three
times, but their roughly 3 MB combined is a smaller opportunity. No GC, full heap
liveness, whole-function allocator or complete source-language compatibility is
claimed by this increment. Crew CLI changes belong to their separate owner.
