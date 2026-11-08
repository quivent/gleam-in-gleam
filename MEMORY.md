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
