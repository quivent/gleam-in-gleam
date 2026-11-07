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
* Strings remain pointers to static `[length:u64][UTF-8 bytes][newline]` data.
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
native results to unmodified upstream-generated JavaScript results. Structural
equality and printing of compound values remain rejected until implemented.

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
