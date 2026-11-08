# Full-size native compilation reliability

Status: implemented and qualified for the complete actual compiler graph.
The sequence below preserves the original plan and baseline; current results follow.
This is roadmap step 2. Baseline: compiler source commit ba5b3c8, native CLI image
582,442 bytes; 631 passing checks and 297 fresh upstream comparisons.

## Historical boundary (before these changes)

The native CLI deliberately rejects sources above 16,384 bytes. Earlier execution
of a 33,036-byte comment-heavy input exhausted the frontend stack; a 24,036-byte
case passed.
The [failure receipt](evidence/native-cli-initial-size-failure.json) preserves the
observations. The whitespace scanner now has a smaller frame, but native tail
calls still grow the stack and the 64 MiB arena has no collection.

At this baseline, the 25 source modules total 230,817 bytes. The largest are
check.gleam (50,640), x64.gleam (41,770), parser.gleam (27,919), project.gleam
(23,226) and cli_runtime.gleam (17,583). A higher byte limit alone would not prove
these inputs compile correctly. Memory allocation and the native self-build
entry also need separate evidence.

## Outcome

Compile representative large sources and the actual compiler input graph through
the owned native compiler path, with recorded stack/memory behavior and controlled
failure for resource exhaustion. Raise the production file bound only after the
new boundary passes. A self-rebuild/identical successive image is step 4.

## Original implementation sequence

1. **Locate the actual stack frontier.** Use bounded, reproducible inputs for
   whitespace, comments, UTF-8, token-heavy code and recursive syntax. Attribute
   failures to actual native call paths/frames. Keep production limits intact;
   any higher-bound diagnostic build must be explicit, isolated and recorded.
2. **Implement the smallest justified stack fix.** Direct self-tail-call lowering
   is the first candidate. Evaluate arguments left to right, save all new values
   before replacing parameter slots, preserve captures/locals and reenter after
   the prologue. Treat tail position explicitly through branches/blocks. Ordinary
   non-tail recursion must preserve its semantics. Confirm loops in actual ASM.
   The exact implementation follows the measured frontier; this is not a claim
   that all stack use is tail-recursive.
3. **Measure allocation costs.** Record arena usage around source loading,
   checking, instruction construction, relocation and byte assembly. The two-pass
   append and repeated concatenation are known candidates. Choose chunking,
   allocation/growth or an owned collection design from evidence; avoid adding a
   runtime dependency or silently weakening overflow checks.
4. **Raise and qualify the boundary.** Test progressively larger files, including
   the actual largest modules and full graph. Compare native/bootstrap emitted
   bytes and execution. Keep failures, limits and source/image hashes. Preserve
   the CLI's rooted reads and no-replace publication behavior.

## Acceptance

* The known large-input failure is reproduced under a bounded diagnostic path and
  its causal native frame/call path is recorded.
* Long direct tail-recursive loops have bounded stack usage and correct output;
  reordered/dependent arguments, branches, guards, closures and non-tail recursion
  have regression coverage. ASM shows the intended loop or other measured fix.
* Allocation profiles identify the remaining memory frontier. Resource exhaustion
  produces an explicit failure and never publishes a partial executable.
* A higher source bound is supported by exact tested sizes/shapes, including the
  largest actual module and representative multi-module inputs.
* Native/bootstrap output comparisons and the existing correctness/IO tests pass.
  Changes to binary layout/hashes are documented rather than hidden.
* The source graph can reach the native self-build entry. Its integration and the
  actual successive-image comparison remain explicit step-4 requirements.

## Boundaries and evidence

No LLVM/Cranelift, libc, external assembler/linker, GC package or VM. Compiler and
runtime logic stay in Gleam. Preserve installed Crew/compiler tools, sessions,
source and historical receipts. Developer probes may use existing host tools;
none becomes a delivered runtime dependency.

## Qualified outcome

The old failure reproduces as SIGSEGV with all 256 sampled frames in the UTF-8
validator (272-byte locals, 296-byte frame stride), while only 1,173,024 arena bytes
are used. The same frozen target source and diagnostic cap succeeds after direct
self-tail lowering. A million tail iterations finish under a 64 KiB stack.

The complete graph next exhausts 64 MiB. Even a diagnostic 512 MiB arena fails
before the closure stream fix. Balanced byte merge rounds and reverse closure
accumulation remove the measured repeated-prefix copies. The full production
source now rebuilds itself twice; all three 592,047-byte images are identical.

Production source cap is 131,072 bytes; compiler arena is 536,870,912 bytes, with
no collection or growth. One actual native self-rebuild allocates 368,525,376 bytes
and peaks at 360,320 KiB RSS. Ordinary programs still use 64 MiB. Snapshots of
stack mappings/usage are not peak-stack measurements or speed benchmarks.

[Scale evidence](evidence/self-hosting-scale-frontier.json) retains causal failures,
source/emitter hashes, caps, frame samples and observations. The
[native rebuild receipt](evidence/self-hosting-native-rebuilds.json) records exact
final inputs and stage-3 corpus results. The
[complete qualification](evidence/self-hosting-qualification.json) includes 657
checks, 317 upstream comparisons and preserved native IO semantics.

General deep non-tail recursion, mutual/indirect tail calls, collection/growth and
unbounded inputs remain outside this qualified result.
