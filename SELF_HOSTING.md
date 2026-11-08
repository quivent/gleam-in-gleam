# Progress toward self-hosting

**A standalone native file-based compiler CLI now works for bounded inputs. A
full-size compiler rebuild and stage-2 comparison remain unproved.** This is a
qualified Gleam subset, not a replacement for upstream. The 70% bar in
[ROADMAP.md](ROADMAP.md) is a subjective milestone estimate.

Build once with `node build-native.mjs out/gleam-native`, then run that executable
without Node. The CLI loads source/imports beneath a selected root and publishes
complete executables without replacing existing paths. It compiles and executes
all sixteen examples with exact bootstrap byte comparisons. Its separate native
API proof still compiles two embedded programs and verifies their emitted bytes.

The CLI bounds sources to 16 KiB each, the graph to 256 files, and uses the existing
64 MiB arena without GC or native TCO. A 33 KiB comment-heavy input exposed a real
stack limit; full-size reliability is next, rather than an assumed solved problem.
The 59 targeted CLI tests include actual kernel short reads/writes, injected
interruptions/errors, Unicode, no-replace publication and effect ABI rejection.
[The IO receipt](evidence/native-cli-io-verification.json) records observations and
actual ELF headers; [the spec](NATIVE_CLI_SPEC.md) defines the bounded contract.

| Area | Actual evidence | Remaining work |
| --- | --- | --- |
| Source compilation | All actual compiler modules compile to native code under a bounded driver | Native compilation of a complete compiler rebuild input |
| Native compiler execution | Two programs emitted, byte-identical to bootstrap output, both execute correctly | Broader native-path qualification and self-rebuild |
| CLI/IO | Owned native arguments, rooted file reads, robust write/publication loops | Lift qualified 16 KiB input bound; full-size reliability |
| Language | Recursive ADTs, closures/use, aliases/guards, product cases, structural equality and exact 53-bit literals | Remaining upstream syntax/inference/imports, erased equality, exact larger literals |
| Runtime | Owned strings/bytes, direct syscalls and checked 64 MiB arena | Native tail-call elimination, collection/allocation scaling |
| Targets/dependencies | Own x86-64 emitter/relocator/ELF, no external runtime/assembler/linker/libc/packages | Additional architectures/OS formats |

The complete regression/upstream run passes **631 tests and 297 fresh upstream
comparisons**, with all sixteen earlier example hashes unchanged. It is recorded in
[evidence/native-cli-verification.json](evidence/native-cli-verification.json).
The earlier 572-test/297-comparison milestone and 498,418-byte API-plus-driver
image are preserved under their original receipt names.

The full prioritized backlog and acceptance evidence are in [ROADMAP.md](ROADMAP.md).

The [interactive roadmap](docs/roadmap.html) exposes the eight specs/evidence;
[the full-size reliability spec](FULL_SIZE_RELIABILITY_SPEC.md) defines the next
bounded implementation sequence.

## Next acceptance steps

1. Extend the delivered bounded native CLI to actual compiler-source scale,
   using measured stack/allocation failures to choose the next runtime changes.
2. Compile complete compiler inputs natively and fix measured resource limits.
   The append change avoids bootstrap stack overflow but uses an extra reversed
   prefix. Its traversals still consume stack in native code until TCO exists;
   the arena has no collection. Do not assume small-input success proves scale.
3. Connect a native self-build entry using `cli_builder.build`, preserving the
   effect runner. Rebuild the exact compiler source with the native compiler, compare the
   stage-1/stage-2 bytes and execute the rebuilt compiler's checks. Only then
   claim native self-hosting.

Historical component proofs for UTF-8, core, type-system and equality planner
remain in evidence and JOURNEY.md. Earlier alias and literal rejections are
preserved under their original receipt names. The Node bootstrap is still used
to create the initial image; the resulting CLI runs independently. No installed
compiler or Crew process has been replaced.
