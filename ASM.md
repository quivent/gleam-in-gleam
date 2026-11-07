# Native instruction and value contract

This is a correctness contract for the seed, not a claim of a finalized ABI or
optimized output. Linux x86-64 only. No external assembler/linker emits the
program. GNU objdump is used only as a development inspection tool.

## Calls and stack

* Each generated function uses `push rbp; mov rbp,rsp; sub rsp,frame_size`.
  The local frame size is rounded to 16 bytes. There is no tail-call elimination.
* Call arguments are evaluated left to right and pushed in that order. The last
  argument therefore lives at `[rbp+16]`; earlier arguments have higher offsets.
  The caller reclaims those argument slots. RAX contains the result.
* Locals and saved match subjects use negative offsets from RBP. Temporary pushes
  cannot change their addresses. Destructuring reads object fields into fresh
  slots before binding names; shadowed outer bindings remain intact.
* R14 and R15 are reserved arena registers. Every generated function preserves
  their meaning. Other general-purpose registers are scratch unless an expression
  has explicitly saved its values. This is an internal convention, not the SysV
  C function ABI. Native foreign calls are not implemented.
* Linux `syscall` destroys RCX/R11; print helpers preserve the language expression
  result in RAX. Live expression values stay on the stack across calls.

## Values and allocation

* Int values are checked signed 64-bit words; Bool is 0/1 and Nil is 0. Types
  distinguish those representations. This is still a documented integer subset.
* Strings remain pointers to static `[length:u64][UTF-8 bytes][newline]` data.
* Empty lists are null pointers. A cons cell is 32 bytes:
  `[size=32:u64][tag=2:u64][head:u64][tail:pointer]`.
* A tuple is `[size:u64][tag=1:u64][field0:u64]...`. Empty tuples still allocate
  a header. Tuple arity/indexing and field types are checked before emission.
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

The runtime tests execute an exact-fit allocator probe and an over-end probe
through these same Gleam emitter/ELF modules. Pure oracle tests compare actual
native results to unmodified upstream-generated JavaScript results. Structural
equality and printing of compound values remain rejected until implemented.
