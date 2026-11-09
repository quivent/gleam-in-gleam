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

## Linking breakdown — investigation before the next rewrite

The next trace uses the same frozen 27-module input, the qualified 644,591-byte
compiler, and independently verifies the 637,775-byte output hash. No compiler
logic changes were made. `--function` now selects exact native symbols for the
development profiler while retaining its build root.

[Phase receipt](evidence/linking-allocation-phases.json) and
[additive detailed summary](evidence/linking-allocation-breakdown.json).
The full 146,255-event trace remains under ignored `out/allocation-profile/`, with
its SHA recorded in the summary. Counts below are observed function entries, not
per-byte loop iteration counts. Totals use exclusive allocation where nested
helpers would otherwise be counted twice. MB here means decimal megabytes.

| Inside linking | Allocated bytes | Share |
|---|---:|---:|
| Name/import/type resolution | 60,433,512 | 49.6% |
| Lexing | 47,853,432 | 39.3% |
| Parsing | 12,053,240 | 9.9% |
| Definitions collection | 1,018,944 | 0.8% |
| Other linking work | 366,736 | 0.3% |
| **Total** | **121,725,864** | **100%** |

### Resolution: 60.4 MB

| Selected path, excluding separately measured nested helpers | Entries | Bytes |
|---|---:|---:|
| Member/value lookup `value_in` | 5,616 | 35,302,152 |
| Module lookup `module_by_name` | 4,645 | 8,249,520 |
| Local-bound-name lookup `local` | 10,297 | 4,562,840 |
| Import lookup `imported` | 5,118 | 2,818,896 |
| Named type lookup `named_type` | 1,548 | 1,651,624 |
| Internal name construction | 6,432 | 545,712 |
| Remaining resolution work | 27 roots | 7,302,768 |

Source inspection explains a concrete opportunity: `value_in` maps all module
functions and constructors into name/publicity pairs, flattens/appends them, then
looks up one name. Module lookup similarly maps every module to a name/module
pair on each call; local-name lookup maps the whole bound list. These are repeated
transient lookup representations. The measured totals include results and other
helper costs too; they are not a prediction that every attributed byte can vanish.
Direct traversal or a module-level reusable index are alternatives to evaluate.

### Lexing: 47.9 MB per pass

| Selected path | Allocated bytes |
|---|---:|
| Token scan/construction and remaining lexing | 20,916,160 |
| Identifier scanning/string accumulation | 10,616,864 |
| UTF-8 validation | 10,434,640 |
| Whitespace scanning | 3,682,848 |
| Quoted strings | 1,323,400 |
| Numeric scanning | 530,584 |
| Comments | 348,936 |

The lexer walks suffix BitArray views, identifiers append one character at a
time, and UTF-8 validation makes a preceding pass using suffix views as well.
These are observed allocation paths, not measurements of retained token size.
A source cursor/span representation and deferred identifier materialization are
possible approaches; they require careful immutable lifetime and UTF-8 semantics.

### A separate duplicate pass before linking

There are **54 lexer calls and 54 parser calls**: 27 of each during dependency
loading, then 27 again under linking. Both passes allocate the same measured
amount: **59,906,672 bytes per lex/parse pass**, or **119,813,344 bytes combined**.
The 59.9 MB before linking is outside the 121.7 MB linking total above. The CLI
currently retains source bytes after discovering dependencies, not the parsed AST,
and `visit` reparses those sources. A parse-once handoff could avoid repeated work;
its actual savings must be measured because retained AST/state also has a cost.
Do not introduce a second authoritative mutable source cache or bypass validation.

### Decision before implementation

The three candidates are: eliminate rebuilt lookup lists, retain parsed modules
across dependency loading/linking, and replace repeated byte-tail/string-building
work with cursor/span operations. None has been implemented by this investigation.
Ask Jay for advice before choosing the next representation/lifetime change.

For example, repeat the coarse trace with fresh output paths:

```sh
python3 tools/profile_native_allocations.py \
  out/allocation-profile/optimized/symbols.json out/link-phases.json \
  out/allocation-profile/optimized/compiler \
  out/allocation-profile/current/source-snapshot/src out/link-rebuilt \
  --expected-output-sha 58065cea325f468ea25f18fea3ca728781dafc43413e59586dabb8427885296e \
  --function link@native/project --function lex@native/lexer \
  --function parse@native/parser --function resolve_module@native/project \
  --function collect@native/definitions --function source_index@native/project \
  --function validate_imports@native/project --function alias_headers@native/project
```

## Implemented: direct lookup, then one immutable parse — 2026-11-08

The architecture stayed clear enough to act in two separable increments rather
than design an elaborate indexing/cache framework first:

1. `6bf1d50` searches existing immutable lists. `core.find` stops at the first match;
   module, import, alias and nominal-type lookups no longer map whole lists into
   key/value pairs. Member lookup checks functions first, then constructor lists,
   preserving precedence, declaration order and visibility. Local membership walks
   the existing names without allocating a parallel list. Results/errors remain
   at the original semantic boundary. No hash table or external dependency was added.
2. `2a140ed` carries `PreparedSource(name, content, parsed)` through CLI loading.
   It retains the original immutable read and AST; dependencies and linking share
   that parse. Raw `Source` callers remain valid, including unreachable malformed
   sources that must not be parsed. No global cache, invalidation protocol, file
   reload, or second authority was introduced. Cycle, visibility, duplicate-source,
   mixed raw/prepared input and source-order behavior remain checked.

The same frozen 27-module input is used at every measured stage. Both frontend
changes emit exactly the same target compiler bytes as the preceding byte-count
backend: `58065cea325f468ea25f18fea3ca728781dafc43413e59586dabb8427885296e`.
This output is the older frozen compiler; current-source native fixed-point proof
is separately recorded in the qualification.

| Same-input rebuilding stage | Allocated bytes | Peak RSS KiB |
|---|---:|---:|
| Before byte-count rewrite | 409,183,952 | 400,128 |
| Byte-count rewrite | 338,729,536 | 331,392 |
| Also direct lookup | 288,852,736 | 282,496 |
| Also retained parse | 228,947,576 | 223,744 |

The two frontend increments save **109,781,960 allocated bytes (32.4%)** relative
to the byte-count stage. Across all three rewrites the saving is **180,236,376
bytes (44.0%)**. Peak RSS is now **218.5 MiB**, versus **390.8 MiB** at the original
baseline. Measured RSS can differ slightly with tracing/launch overhead; these are
observed values, not an identity between resident and allocated bytes.

Within linking, resolution falls **60,433,512 → 10,673,728 bytes**. Total linking
falls **121,725,864 → 11,941,584 bytes** after both changes. The trace observes
**27 lexer calls and 27 parser calls**, all during loading, instead of 54 each
split between loading and linking. The retained state has a small allocation cost;
net measured savings, rather than subtracting an assumed pass cost, are reported.

[Comparison](evidence/parsed-snapshot-allocation-reduction.json),
[lookup trace](evidence/lookup-search-allocation-phases.json),
[retained-parse trace](evidence/parsed-snapshot-allocation-phases.json),
[whole-phase trace](evidence/parsed-snapshot-full-phases.json).

The lookup-only qualification passes 744 tests. The final qualification passes
**748 tests**, **383 upstream comparisons**, and all native stage-3 corpus cases.
Two self-rebuilds are byte-identical to the 645,969-byte native seed, SHA256
`7bb657841b0505ce9d44dba875c5654cb7d3dee23a65968f205f22e8b29b0b5f`.
Nine complete examples in [GUIDE.md](GUIDE.md) also compile and execute with checked
outputs; that separate receipt is not added to the regression-suite count.

[Qualification](evidence/parsed-snapshot-qualification.json),
[native rebuilds](evidence/parsed-snapshot-native-rebuilds.json),
[guide executions](evidence/parsed-snapshot-guide-execution.json).

### Where the cost moved

The new whole-phase trace still observes code planning at **82,964,584 bytes**,
type checking at **41,866,200**, assembly at **30,210,408**, and ELF packaging at
**638,168** on the frozen input. These are inclusive phase volumes: code generation
contains planning/assembly, so do not sum nested categories. Source intake now does
one real lex/parse pass and retains its AST. Code planning is the next measured
candidate, rather than continuing to optimize linking merely because it was once
largest. There is still no GC or third-party native dependency.

These choices are revisable. Direct scans may eventually become reusable indexes;
AST lifetime management may change. Preserved commits, fixed-input measurements,
explicit raw/prepared APIs and the full supported language guide make that revision
possible without hiding semantic regressions behind a broad architectural rewrite.

### Timing: a memory win, without a broad speed claim

The final five-repeat untraced comparison uses the preceding byte-count compiler
as baseline. Median CPU is **4.833 → 4.730 seconds** (2.1% lower); median wall time
is **5.102 → 5.150 seconds** (0.9% higher). Untraced maximum RSS is **323.6 → 218.9
MiB**. The earlier trace measured 218.5 MiB; retain that run distinction. Allocation
reductions do not translate proportionally into timing improvements. Other phases
remain unchanged and the arena allocator itself is simple. [All samples and ranges](BENCHMARKS.md)
are retained, including the separately measured lookup-only increment.

## Instruction spans: carry a planned sequence once

An already-planned instruction body has known order and ownership. Rebuilding
its list spine to join it to another body adds no semantic information. The
planner can preserve that structure directly through lowering and assembly.

`assembler.Part` now admits `Span(List(Part))`. `assembler.join` shares longer
immutable sequences and directly prepends tiny prefixes. X64 lowering composes
those spans instead of repeatedly reversing/copying full lists. Closure helpers
are retained once as spans in reverse helper order; final order is restored at
program assembly. This does not reverse instructions inside an individual helper.
Environment bindings and equality metadata retain their ordinary list semantics.

Both assembler passes use an explicit pending-sequence stack. They walk nested
spans in order, maintaining the same global byte offset, label namespace, duplicate
label checks and signed relocation checks. There is no preliminary flattened plan
copy. Output chunks still use the existing balanced byte concatenation.

On the identical frozen 27-module input:

| Allocation phase | Before | With instruction spans |
|---|---:|---:|
| Code planning | 82,964,584 B | 28,830,568 B |
| Assembly | 30,210,408 B | 31,665,000 B |
| Whole rebuild | 228,947,576 B | 176,268,104 B |
| Peak RSS, trace | 223,744 KiB | 172,544 KiB |

Planning allocation falls **65.3%**. Assembly spends an additional 1,454,592 bytes
walking the explicit sequence structure; whole-build allocation still falls
52,679,472 bytes (23.0%). Peak RSS is **168.5 MiB**, down from 218.5 MiB in the
preceding trace. The emitted fixed-input target compiler remains byte-identical:
`58065cea325f468ea25f18fea3ca728781dafc43413e59586dabb8427885296e`.

This is a representation/memory result. It does not by itself establish a runtime
speedup or make arbitrary effectful branches safe to evaluate eagerly. Gleam's
existing evaluation order, short-circuiting and overflow behavior remain required.
[Actual allocation trace](evidence/instruction-spans-allocation-phases.json).

## Throughput/index tradeoff — 2026-11-09

The fused assembler replaces quadratic label scans with an immutable balanced
index. On the identical current 28-module input, total arena allocation changes
183,603,232 → 209,172,536 bytes. Repeated untraced maximum RSS changes
175.88 → 200.25 MiB. This is an intentional speed/storage tradeoff, not another
allocation reduction: the combined pass uses 91.63% less compile CPU, while its
index retains/copies more nodes. Context reuse removes two redundant collections,
but does not offset the index cost. No collector was added.

See [the controlled three-way timings](evidence/fusion-full-compilation.json),
[before cursor trace](evidence/fusion-same-input-before-phases.json) and
[after cursor trace](evidence/fusion-same-input-after-phases.json). Earlier frozen
27-module allocation results above remain their own experiments; do not splice
them into a current-source memory score. Next: compact index/hash traversal
storage while preserving collision correctness and exact-output qualification.
