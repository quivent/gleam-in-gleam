# Native instruction and value contract

This is a correctness contract for the seed, not a claim of a finalized ABI or
optimized output. Linux x86-64 only. No external assembler/linker emits the
program. GNU objdump is used only as a development inspection tool.

## Calls and stack

* Each generated function uses `push rbp; mov rbp,rsp; sub rsp,frame_size`.
  The local frame size is rounded to 16 bytes. There is no tail-call elimination.
* Unlabelled call arguments are evaluated left to right and pushed in that order. The last
  argument therefore lives at `[rbp+16]`; earlier arguments have higher offsets.
  The caller reclaims those argument slots. RAX contains the result.
* Labelled constructor calls are rearranged into declaration order before
  checking/lowering, which is also upstream Gleam's observable evaluation order.
  There is no runtime label lookup, argument-shuffling helper or dynamic dispatch.
* Locals and saved match subjects use negative offsets from RBP. Temporary pushes
  cannot change their addresses. Destructuring reads object fields into fresh
  slots before binding names; shadowed outer bindings remain intact.
* R14 and R15 are reserved arena registers. Every generated function preserves
  their meaning. Other general-purpose registers are scratch unless an expression
  has explicitly saved its values. This is an internal convention, not the SysV
  C function ABI. Native foreign calls are not implemented.
* Linux `syscall` destroys RCX/R11; print helpers preserve the language expression
  result in RAX. Live expression values stay on the stack across calls.
* First-class functions are pointers to arena-owned descriptors:
  `[size:u64][tag=0:u64][code:pointer][capture0:u64]...`. A named monomorphic
  function allocates a 24-byte descriptor without captures. Generic types are
  checked/instantiated at compile time, with no runtime type arguments.
* Closure creation copies free local value words into that descriptor. Pointer
  values refer to other arena objects or static data, never a former stack slot.
  Each helper has its own stack frame; nested helpers retain their own captures.
  Arena ownership keeps returned captures alive until exit; collection is pending.
* An indirect call evaluates and pushes its descriptor before evaluating/pushing
  arguments. It reloads the descriptor at `[RSP + 8 * argument_count]`, rejects
  null/wrong tag, loads and checks its code pointer at offset 16, then executes
  `call *RAX`. It reclaims argument words **and** the saved descriptor word.
  Explicit parameter offsets remain unchanged.
* A closure helper reads the saved descriptor at
  `[RBP + 16 + 8 * argument_count]` and copies capture fields (offset 24 onward)
  into its own local slots. Named callees ignore that hidden descriptor word.
  Code stays in the ELF's read/execute segment; descriptor memory is read/write,
  non-executable. This is an internal ABI, not an FFI contract.
* `use` is frontend callback lowering. It adds no separate runtime mechanism.

## Values and allocation

* Int values are checked signed 64-bit words; Bool is 0/1 and Nil is 0. Types
  distinguish those representations. This is still a documented integer subset.
* String value pointers expose `[length:u64][UTF-8 bytes][newline]`. Literals
  remain static; dynamic values have an arena header before the value pointer
  (see the strings milestone below).
* Empty lists are null pointers. A cons cell is 32 bytes:
  `[size=32:u64][tag=2:u64][head:u64][tail:pointer]`.
* A tuple is `[size:u64][tag=1:u64][field0:u64]...`. Empty tuples still allocate
  a header. Tuple arity/indexing and field types are checked before emission.
* Custom constructors use that same header/field layout, with deterministic
  tags starting at 3 in source declaration order. A zero-field constructor is
  still an allocated 16-byte object, not an immediate integer or a function.
  Tags identify constructors across the single compiled module. Nominal types
  are checked before lowering; similar object layouts do not make types equal.
* Generic type applications reuse the constructor's tag and one-word field
  representation. Substitution/inference happen only in the compiler. Int,
  Bool and pointer fields all occupy one word in this subset, so no runtime
  type dictionary, monomorphized constructor or per-instantiation layout is needed.
  This contract currently applies to generated/type-checked calls; native FFI
  and arbitrary external values are not implemented.
* Tuple fields and list heads are evaluated left to right. Cons construction
  pops the evaluated heads right to left to create the list spine. Existing list
  tails are shared and never mutated.
* If any compiled function constructs a compound value, entry initializes one
  64 MiB anonymous private arena with `mmap`: RAX=9, RDI=0, RSI=67108864,
  RDX=3 (read/write, **not execute**), R10=34, R8=-1, R9=0. Programs that do not
  allocate retain their previous code and do not map the arena.
* R15 is the bump pointer, R14 the exclusive end. Allocation returns old R15 in
  RAX, advances by an already 8-byte-aligned size in RDI, checks unsigned carry
  and then checks `R15 > R14`. Exact fit is valid. Failure exits 71 before an
  object write. The allocator does not collect or grow; the kernel releases the
  arena on process exit. This is not the final memory-management implementation.

## Branches and memory access

* Short-circuit operators branch before evaluating the right operand.
* Every list head/tail pattern tests the current list pointer for null before
  dereferencing it. Nested patterns guard each cons step independently. A failed
  pattern jumps to the next arm with its source-level environment restored.
* Exact-length patterns also check that the remaining tail is null. A spread
  pattern binds/shares the remaining tail. Irrefutable tuple let-patterns are
  checked statically; refutable lets are rejected until let-assert is supported.
* Constructor matches first test for null, then compare `[RAX+8]` with their
  checked tag and branch on mismatch. Only then can they load fields starting
  at `[RAX+16]`. Nested constructors repeat that sequence independently.
  The disassembly retains those checks even when a constructor is statically
  known. No speculative field read or tag-check-elision pass is implemented.
* Labelled patterns are resolved to declaration positions at compile time. A
  spread pattern fills unspecified fields with discards; it does not alter the
  native object layout. Field access checks null and membership in the possible
  constructor-tag set, then reads the statically checked offset. Common fields
  must have identical declaration positions and formal types across variants,
  even when a particular generic instantiation could make unlike types coincide.
* Known constructor facts are separate from the value's nominal type. They can
  flow through a simple local variable, but do not automatically refine its
  fields or function parameters. This prevents a known outer wrapper from
  incorrectly proving that its nested value has only one possible variant.
* Case exhaustiveness is conservative: Bool alternatives, irrefutable tuples,
  empty/nonempty lists with irrefutable head/tail, and catch-all patterns are
  understood. Complex coverage may be rejected rather than accepted unsafely.
* Integer overflow or an impossible match exits 70. Division/remainder by zero
  return zero. Arithmetic never silently wraps.

## Inspection evidence

`verify.py` records a raw disassembly for the collection example when objdump is
available. The ELF intentionally has no section table, so the verifier extracts
bytes starting at its entry point and uses binary disassembly with the actual
virtual address. Trailing static data can appear as meaningless instructions;
it is not executed and must not be mistaken for generated control flow.
The custom-type example also has a recorded raw disassembly. Its recursive-tree
and nested-pattern paths exhibit the null test, tag comparison, conditional
branch, then field load sequence. Both examples execute without a loader or
shared libraries; their recorded byte sizes are example sizes, not compiler size.

For custom-type milestone artifact SHA256
`7a45a359782b385ad041969a0d02411f99c12fab07742b4512a1888c11d26d82`,
the recorded disassembly shows a null test at `0x4000e3`, a Leaf tag comparison
at `0x4000ec`, a mismatch branch at `0x4000f4`, then the first field read at
`0x400101`. The Open-pattern comparison at `0x400397` branches away from its
field read when the actual object is Closed, which has no fields. These addresses
refer to this exact frozen example, not to future layouts.

For generic-record example SHA256
`dc7d2a6c6d337956c7eb57afe4b035a7692be212cf4e6aa91ffc0f9e44c2f1e4`,
the `.count` access compares Envelope tag 5 at `0x40024b`, branches to the field
load at `0x40025e` on equality, and otherwise jumps to the failure exit. The load
uses offset `0x18` (header plus the second word-sized field). Its 874-byte size
is the complete example program, not the compiler. Numeric output `21,2,21,2`
also confirms declaration-order evaluation despite reversed source labels.

For the historical raw-pointer function example SHA256
`58c74b37a69a36b676c0719bb5c598c642f7da042205cd2434280babeded6d68`,
`twice` reloads its saved target at `0x4000e6`, null-checks it and calls through
RAX at `0x4000f7`. The cleanup at `0x4000f9` advances RSP by `0x10`: one argument
word and one target word. The outer call then repeats that sequence at
`0x400101`–`0x400114`. Named `increment` references use RIP-relative LEA, such as
`0x4001ab`, targeting its actual entry at `0x40011d`. The 867-byte artifact is the
example executable, not a measured compiler binary or a speed benchmark.

The runtime tests execute an exact-fit allocator probe and an over-end probe
through these same Gleam emitter/ELF modules. Pure oracle tests compare actual
native results to unmodified upstream-generated JavaScript results. Compound
printing remains unsupported; structural equality is implemented below.

## Closure milestone inspection

For closure example SHA256
`5189b1237e01dc24846d1c3ea8ea49e201c5098f9802fbc47a6912eaf959cca0`,
`evidence/closures-disassembly.txt` shows the static helper address loaded at
`0x4000ef`, stored in descriptor offset 16 at `0x4000f6`, and its captured value
stored at offset 24 at `0x4000fb`. An indirect call checks tag 0 at `0x400130`,
loads the code pointer at `0x40013b`, calls at `0x400148` and reclaims two words at
`0x40014a`. The one-argument helper starts at `0x400289`: it reads its saved
descriptor from `[rbp+24]` at `0x400294`, then reads the captured value from
`[rax+24]` at `0x40029b`. Its explicit argument remains at `[rbp+16]`.

The complete 1,021-byte native example prints `12,22,6`, including two distinct
returned environments. Named-function descriptors deliberately change the earlier
function example to 1,050 bytes; its current listing is
`evidence/functions-descriptor-disassembly.txt`. The old raw-pointer listing
above remains historical evidence, not the current ABI. Neither artifact size
is compiler size or a performance benchmark.

## Record-update milestone inspection

Record update lowering uses an internal scoped binding for the original and
existing checked field loads plus constructor allocation. It adds no new native
instruction family, mutation operation or dynamic label lookup. Source replacement
expressions evaluate in declaration order after evaluating the original once.

For record-update example SHA256
`e9f4236e62b01c9351f170ee36fbdc3005f2bb40aab7986f2c23bd5e8913042a`,
the original pointer is saved at `0x40011b`. The retained first field is read at
`0x400145` after null/tag checks. The replacement 7 is loaded at `0x40014d`, then
the new allocation is called at `0x40015d`. Stores at `0x400172` and `0x40017a`
write into the new object, leaving the original unchanged. The later all-field
replacement still loads/saves the original at `0x400188`/`0x40018f`, before creating
its Bool fields. Runtime output is `3,7,True`. The full executable is 930 bytes.

The assembler's relocation emission now uses a reversed chunk accumulator and a
direct tail-recursive traversal, avoiding one bootstrap host stack frame per
instruction. Relocation offsets/order are unchanged: all seven older example
binaries retain their previous SHA256 values. A dedicated regression checks a
forward jump over 12,000 instructions and rejects an unresolved label.

## Byte-aligned bit arrays

The current owned buffer layout is:

```text
[aligned object size:u64][tag=-1:i64][byte length:u64]
[data pointer:u64][root owner:pointer][inline payload bytes...]
```

An owned allocation uses `align8(40 + byte_length)` and points its owner field to
itself. A slice is a 40-byte descriptor with adjusted length/data pointer and the
same root-owner pointer; it does not copy payload bytes. Explicit ownership avoids
requiring a future collector to infer the allocation from an interior data pointer.
The current arena retains all values until exit, so no reclamation is claimed.

Construction evaluates nonzero segment expressions in source order and saves the
values in frame slots. Statically zero-width integer expressions are checked but
not evaluated, matching upstream. Length sums, header/alignment addition and arena
allocation are checked before writes. Integer segments copy the low bytes with
explicit shifts; bit-array segments use `cld; rep movsb`. No external memcpy or
endian library is involved. These straightforward instructions prioritize verified
semantics; instruction selection has not been optimized or benchmarked.

Patterns check tag and exact/minimum length before reading any data. Fixed integer
reads assemble bytes with shifts/OR; signed reads sign-extend the requested width.
Unsigned 64-bit variable extraction with its high bit set exceeds the documented
native signed Int range and exits 70. Literals instead fail to match, and discards
remain valid, avoiding an incorrect negative interpretation. Pattern tails allocate
only the shared descriptor and preserve the root owner.

For artifact SHA256
`3a6246603edd9e0564244ccf98899133111713eff214b49d0bdb3a391dd0c849`,
`evidence/bit_arrays-disassembly.txt` shows minimum-length checking at `0x40012f`
and its failure branch at `0x400137`, before the first byte load at `0x40014a`.
A returned tail copies the root-owner field at `0x4001a1`/`0x4001a5`. Root allocations
store their own address into that field, for example at `0x400286`. Concatenation
copies bytes with `rep movsb` at `0x40039a`. The full 1,825-byte example prints
`5,9,-2,4660`. All eight earlier example executables remain byte-identical.

## Local module resolution and static linking

The project pass assigns unlexable internal names such as
`add@module_demo/numbers` and `Box@module_demo/box` to dependency declarations.
The entry module retains its original names, including the single `main` entry.
Imports are removed from the resolved AST before checking. Type identity and
visibility are validated before lowering; no runtime dictionary of module names,
PLT/GOT or dynamic linker is added. Generic type arguments remain erased.

The owned relative-relocation pass links ordinary function code in deterministic
DFS postorder. Shared dependencies appear once, and cycles fail before codegen.
Constructor tags are assigned to the resulting module-qualified declarations, so
same-named types/constructors from different modules cannot collide. This is the
existing internal ABI, not an external object-file format or cross-package FFI.

For the module example SHA256
`58afdd9c3f748246bf4ebe29c7cd63a884c0b94daeaeaf4aac1734cbec4856f2`,
`evidence/modules-disassembly.txt` shows the entry call at `0x4000b5` reaching
root `main` at `0x40013b`. Root code directly calls imported `twice` at `0x4001c5`,
reaching its body at `0x4000e9`; that body calls its private module-local `add` at
`0x400104`, reaching `0x4000c3`. The imported `increment` function value uses the
existing descriptor ABI: its code address is loaded at `0x4002c8`, targeting
`0x400112`, and called indirectly at `0x400316`.

The complete executable is 1,060 bytes and prints `14,8,3`. All nine earlier
artifacts retain their previous hashes. A separate fixture compares the complete
module output against equivalent single-module machine code and finds identical
bytes. That demonstrates static name erasure for that fixture, not a universal
compiler or runtime performance claim.

## Transparent aliases and guarded case arms

Aliases expand in their defining module's type scope before checking/lowering.
They generate no wrapper, tag, allocation, call or runtime type dictionary. An
exact-byte test compares generic tuple aliases with explicit tuple annotations and
finds identical full executables. Nominal recursive types remain distinct, and
alias expansion validates cycles independently of runtime constructor recursion.

Each guarded arm emits pattern checks/bindings first, then its condition using the
existing expression instructions. `test rax,rax; jz next_arm` branches on false;
only a true condition reaches the body. The saved subject and outer environment
remain available for subsequent arms. Unguarded arms retain their previous bytes.
Guard expressions are typed/restricted before codegen; short-circuit operators
retain their existing branch semantics, including skipping unreachable overflow.

For example SHA256
`c2aa57c17222ca19bb173e4c3f6455b02ff20003f042b85c90fb76b10fcaff96`,
`evidence/aliases_guards-disassembly.txt` shows tuple-field extraction before the
comparison at `0x400116`, guard-result testing at `0x400120`, and the false branch
at `0x400123` reaching the next arm at `0x400135`. That next arm reloads the original
saved subject rather than reusing a guard expression result.

The example closure's capture is loaded from its descriptor at `0x400359` and
stored locally at `0x400360`. Its guard compares the argument with that saved
capture at `0x400393`; the false branch at `0x4003a0` selects False at `0x4003b5`.
The complete 1,269-byte executable prints `7,5,True,False`. All ten prior examples
retain their exact hashes. These are correctness/representation checks, not timing
benchmarks or a measured native compiler size.

## Owned strings and implicit Result

String concatenation and tail copying allocate:

```text
[aligned size:u64][tag=-2:i64][byte length:u64][UTF-8 bytes][newline][padding]
                               ^ returned String pointer (allocation + 16)
```

The size is `align8(25 + length)`. Both length addition and header/alignment
addition are checked before the existing arena allocator is called. The hidden
header keeps heap objects identifiable, while the exposed length/data/newline
layout remains compatible with all static strings and the existing print helper.
A future collector must account for the fixed interior value-pointer offset;
current lifetime comes from the retained arena, not reclamation. Prefix tails
copy their payload into owned storage instead of returning stack/interior views.

Only used string helpers are emitted. Equality and prefix-discard matching do not
require allocation/heap startup by themselves. Helpers use explicit lengths and
`cld; repe cmpsb`; concatenation/tail copies use `cld; rep movsb`, with no external
memcmp/memcpy/malloc. Empty strings take an explicit equality/prefix success path
before CMPSB, avoiding dependence on stale flags for zero iterations. R14/R15 retain
the arena meanings throughout helper calls. The String-to-UTF8 byte-array path
copies only length bytes, excluding the diagnostic newline.

For example SHA256
`d6bd4fc63a544b0777cf6e3aac45eed54b9743d894efc5d91898ceef75dbe610`,
`evidence/strings_prelude-disassembly.txt` shows equality's length comparison at
`0x400555` and mismatch branch at `0x400558`, before CMPSB at `0x400570`. Prefix
matching rejects a shorter subject at `0x40058f` before CMPSB at `0x4005a7`.
Concatenation checks the length sum at `0x4005d3`, alignment addition at `0x4005e1`,
then allocates at `0x4005ee`; left/right byte copies occur at `0x40061d`/`0x40062b`.
The heap string tag is stored at `0x4005f6` and the final newline at `0x40062d`.

Implicit Result is a normal generic ADT under reserved unlexable internal names.
Its two constructors are indexed after user constructors, preserving all previous
tags. There is no Result-specific VM, helper library or runtime dictionary; unused
prelude definitions emit no code. Source resolution checks local names first and
never treats implicit constructors as an imported module's exports.

The complete example is 1,852 bytes and all eleven previous example hashes remain
unchanged. Actual outputs and raw instructions establish correctness for the tested
cases, not compiler speed, a final ABI or full self-hosting.

## Multiple subjects and alternative rows

Each case subject is evaluated once in source order and stored in its own frame
slot. The control-flow lowering allocates no artificial tuple or other heap object.
Subject expressions and patterns can still allocate their ordinary values.

Each arm allocates canonical frame slots for its common binding names. Alternative
matchers may find a name in different positions; after an entire row succeeds,
word copies move the selected bindings into those canonical slots. The shared
guard/body therefore sees consistent addresses. Guards are emitted per alternative:
false branches retry the next alternative, while success reaches the single shared
body. This matters when overlapping alternatives bind different values. Failed
rows/guards never carry their temporary name mapping into later arms.

For artifact SHA256
`cc9b4d05453194a056ba6b6a9589aca5b30888e5199f5f4f04927ec92ff1d44c`,
`evidence/multi_patterns-disassembly.txt` shows the first subject saved at
`0x4000d0` and the second at `0x4000de`. In the guarded function, the first candidate
is copied to the canonical binding slot at `0x400190`. Its false guard branch at
`0x4001b7` reaches the second matcher at `0x4001c2`, which reloads the second saved
subject and copies it to the same canonical slot at `0x4001c9`. A true condition
from either alternative reaches the shared body at `0x400200`.

The complete 1,146-byte executable prints `7,9,3`. Entry calls main directly at
`0x4000b0`; no heap initializer or synthetic subject tuple is emitted. All twelve
previous artifacts retain their exact hashes. The separate core-plus-driver native
receipt measures 12,064 bytes and validates actual owned source on bounded inputs;
neither number is a complete compiler size or a speed benchmark.

## Typed structural equality

`native/equality` builds a finite typed layout graph. `native/equality_runtime`
emits helpers with RCX=left and RAX=right, returning Bool in RAX. R14/R15 arena
registers are preserved and comparison allocates nothing. Pointer identity is a
valid fast path for the supported immutable, reflexive types; functions and stored
erased type parameters are rejected. Primitive scalar/string code stays unchanged.

Tuple and nominal helpers save operand pointers in a 16-byte frame, compare tags
before reading fields, and call the appropriate child helper. BitArray equality
compares byte lengths and payload bytes, ignoring descriptor/owner identity.
Empty payloads succeed without a memory read. List helpers save the next pair
before comparing heads, then loop over tails rather than growing one frame per
list cell. Recursive nested values still consume stack; this is not general TCO.

For the 2,602-byte artifact SHA256
`172f4ae1c8f01fb1682aedf961eee286c0b84fec91a199bdfe89262b9d242a38`,
`evidence/structural_equality-disassembly.txt` shows nominal tags compared at
`0x4005d6`. The string field calls its wrapper at `0x40064b`; the wrapper at
`0x40069d` jumps to the existing string comparison at `0x4008de`. The recursive
list-head call at `0x400706` reaches the Tree helper at `0x4005a7`; the tail
back-jump at `0x400714` reaches `0x4006b2`. A separate 10,000-cell equality test
checks that tail traversal does not recurse. All thirteen older examples retain
their exact hashes. No runtime-speed claim is inferred from these instructions.

## Pattern aliases reuse subject slots

An alias adds a name-to-slot mapping to lowering state, then lowers its inner
pattern against that same subject. No runtime object copy, heap allocation or
additional alias store is emitted. Pattern extraction and later variable reads
still emit ordinary instructions.

In `evidence/pattern_aliases-disassembly.txt`, total's subject pointer is saved at
`0x4000d5` in RBP-8. The nested integer is stored separately at `0x400108` in
RBP-16. Reading `whole.value` reloads the original subject at `0x400117`; its
checked field read is at `0x40013a`. There is no allocator call in total. In main,
the tuple is saved at `0x40020c`; reading `pair.0` reloads that same slot at
`0x400257`. The two allocator calls construct the original Value and tuple, not
alias copies. This is actual instruction inspection, not a timing benchmark.

The alias example is 884 bytes, SHA256
`d78b45bc9744a36045a3d4047f426bc4843265ee562117acc74dcddaf3a2b174`,
prints `14,10`, and needs no dynamic loader/shared libraries. All fourteen earlier
example hashes are unchanged. The final alias suite passes 546 checks and 276
fresh upstream comparisons; this remains subset evidence, not full conformance.

## Wide integer patterns and the native compiler API

Decimal source magnitudes are bounded to 2^53-1 for exact bootstrap representation;
that does not reduce the generated Int arithmetic's checked signed-64-bit range.
For patterns in signed imm32 range the old `cmp rax,imm32` bytes stay unchanged.
Other supported values load a full immediate into scratch RDX with `48 BA imm64`,
then compare RAX/RDX with `48 39 D0`. Failure still branches through the same
matcher path. RDX is scratch in the existing ABI; subject values remain in slots.

`evidence/wide_patterns-disassembly.txt` shows `movabs $0x100000000,%rdx` at
`0x4000de`, followed by `cmp %rdx,%rax` at `0x4000e8` and mismatch branch at
`0x4000eb`. Zero therefore cannot match 4_294_967_296 through truncation. The
maximum supported literal appears as `movabs $0x1fffffffffffff,%rax` at
`0x400195`. Unary negation of magnitude 2_147_483_648 is emitted at `0x4001ae`.

The full compiler API-plus-driver image executes the same owned emitter/assembler/
ELF code natively. Its two emitted programs are compared byte-for-byte against
bootstrap results and executed; the proof also inspects the actual ELF headers of
the compiler and children for absence of dynamic loader/segment and an RW,
non-executable stack. Native tail calls, GC and full-size self-rebuilding remain
unimplemented/unproved; successful small-input compilation is not a scale or speed
benchmark.

The wide-pattern example is 662 bytes, SHA256
`28d44ea87e06a0a11702cd14c3168c626cc0d442ff27f31dae810167af919ba7`.
The current native compiler API-plus-driver is 498,418 bytes, SHA256
`942095a73e00d715e43ab34f7f2a62ce3c3cfce95bb78e54e0ea95d95383afec`.
Its generated 380- and 745-byte children execute and match bootstrap bytes exactly;
all fifteen previous examples remain byte-identical. Those measurements establish
specific artifacts and execution, not a final compiler size or performance result.

## Owned native CLI effect runner

The CLI build selects an explicit entry/runner; ordinary generated programs keep
their previous entry ABI and hashes. The CLI preserves the initial kernel stack
through its own RBP frame, initializes the arena, calls Gleam main and dispatches
Request constructor tags. Native IO returns ordinary typed Result values to Gleam
callbacks. Constructor owner/type/label order and callback signatures are validated
against the resolved context before code generation.

The runner's temporary C strings use owned tag -3 buffers; normal Strings retain
tag -2/value-pointer layout. Argument validation uses a temporary stack BitArray
descriptor while kernel argv remains live, then copies a validated String. Source
buffers use normal tag -1 descriptors with owned payloads. No GC is implied by
these headers. Internal helpers save live values in frames across syscalls and
Gleam calls, preserve R14/R15 semantics and treat RCX/R11 as clobbered.

For image SHA256
`d3428f3554f4fbce00f18e8a0fcb52cceeccd332b4e47b15e41b9580648fc39e`,
`evidence/native-cli-disassembly.txt` contains selected real instruction windows.
Entry establishes RBP at 0x4000b1 and loads request tags at 0x4000cc. Read builds
an initialized 24-byte open_how and issues syscall 437 at 0x488bd0; the -EINTR
comparison branches back at 0x488bd9. Write calls its complete-write helper at
0x48902c, fchmod at 0x489054, fsync at 0x48907c, and close at 0x4890b5. That close
has no retry branch. R8D=1 at 0x4890e9 supplies RENAME_NOREPLACE before syscall
316 at 0x4890f4. These are instruction windows, with trailing instructions, not a
symbolized disassembly of every function.

The trace harness actually reduces read/write RDX requests before the kernel runs;
recorded positive short IO still yields byte-identical output. Separate injected
errors test retry/cleanup branches. Full-size stack handling, native tail-call
elimination and memory collection remain future work; the first native CLI uses
an explicit 16 KiB source-file bound.

## Direct self-tail lowering and scale-qualified image

The first self-hosting image was 592,047 bytes, SHA256
`752240b4e5ab9bb926e171614468790d4a21f168ef3a70d04e9c6d0897e98fbb`.
The previous instruction addresses above describe the older named image.
Current CLI instruction windows are in evidence/self-hosting-disassembly.txt.

Each named function has zero-byte start/loop/end labels. The loop starts 11 bytes
past the entry, after push RBP, mov RSP→RBP and sub frame,RSP. A returned direct
self-call evaluates and pushes arguments left-to-right, then pops all new values
in reverse order into RBP+16,+24,..., and jumps to that loop. It preserves the
original frame/return address and any hidden descriptor word. No partial parameter
update can alter another argument. Function body fallthrough still uses leave/ret.

Tail context propagates only through returned blocks/cases. Closure helpers,
operands, echoes, let RHSs, mutual calls and indirect calls retain ordinary calls.
The objdump assertions in test/tail-calls.test.mjs verify both the loop jump and
non-tail call, and million-iteration runs use an actual 64 KiB RLIMIT_STACK.

Balanced concat merges adjacent chunks without reordering bytes. Closure helpers
accumulate as a reversed instruction stream and reverse once at final layout;
this avoids copying every preceding helper while preserving physical order.
Both changes are compiler-side allocation fixes, not a new generated runtime.

The CLI initializes a bounded 512 MiB arena; ordinary programs retain 64 MiB.
R14 is its end and R15 its cursor. Neither is available to a register allocator.
One rebuild used 368,525,376 arena bytes; this is not spill-space or a GC heap claim.

Next: measure actual frame-memory and push/pop traffic before introducing register
retention. Look-ahead may avoid materializing redundant intermediates, but cannot
reorder effects or move a trap. RAX/RCX/RDX and other scratch registers are clobbered
by internal helpers as documented by their actual instructions. Linux syscall
clobbers RCX/R11. Any values live across these boundaries need explicit spills or
a preserved-register convention; do not infer that the internal stack ABI is SysV.

## Bounded leaf register retention

The operator ABI stays RCX=left, RAX=right. A typed Integer/Bool/Nil/local RHS
cannot call or clobber RCX. Leaf left operands materialize directly in RCX;
compound left results move from RAX to RCX only after their evaluation completes.
A non-leaf RHS keeps push RAX, ordinary RHS evaluation, pop RCX. No retained
register value crosses an unknown helper/call/syscall boundary. Short-circuit
branches and checked arithmetic remain unchanged.

On the exact e099363 target source, the new emitter removes 260 push/pop pairs
and 451 static named-function instructions. The image is 334 bytes smaller;
frame-memory counts are unchanged. Actual ASM and identities are in
[evidence/leaf-register-comparison.json](evidence/leaf-register-comparison.json).
The newer compiler's own added implementation changes its size separately.
General allocation and live intervals are not implemented by that leaf increment.

## Sibling-case frame reservation

Each single/multi-case arm starts after the shared subjects and existing outer
locals. Emit its pattern/guard/body, remember its slot high-water mark, and compile
siblings from the same initial slot count. The join reserves the maximum of those
marks. All frame offsets remain RBP-relative and 16-byte frame rounding is unchanged.
No outer/subject slot is reused, no helper frame is merged, and copied heap captures
cannot retain a pointer to a recycled local. Alternative rows keep their earlier
conservative allocation. There is no general whole-function liveness pass here.

Actual fixed-source frame reservations and the 208→32-byte non-tail workload are
recorded in evidence/branch-slots-frame-comparison.json and
evidence/branch-slots-small-stack.json. Neither record is a timing benchmark.
