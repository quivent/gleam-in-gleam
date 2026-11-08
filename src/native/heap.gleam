// Bounded RW arena acquired through Linux mmap; ordinary programs use 64 MiB.
// R15 is the next allocation address; R14 is the arena end. No collection yet.
// Generated functions reserve both registers. The arena is never executable.
import native/assembler as asm

pub fn runtime() -> List(asm.Part) {
  runtime_sized(67_108_864)
}

pub fn runtime_with_capacity(capacity: Int) -> Result(List(asm.Part), String) {
  case
    capacity >= 67_108_864 && capacity <= 1_073_741_824 && capacity % 4096 == 0
  {
    True -> Ok(runtime_sized(capacity))
    False ->
      Error("Arena capacity must be page-aligned and between 64 MiB and 1 GiB")
  }
}

fn runtime_sized(capacity: Int) -> List(asm.Part) {
  [
    asm.Label("rt:heap_init"),
    asm.Bytes(<<
      184,
      9,
      0,
      0,
      0,
      49,
      255,
      190,
      capacity:32-little,
      186,
      3,
      0,
      0,
      0,
      65,
      186,
      34,
      0,
      0,
      0,
      73,
      199,
      192,
      255,
      255,
      255,
      255,
      69,
      49,
      201,
      15,
      5,
      72,
      133,
      192,
    >>),
    asm.Relative(<<15, 136>>, "rt:oom"),
    asm.Bytes(<<
      73,
      137,
      199,
      73,
      137,
      198,
      73,
      129,
      198,
      capacity:32-little,
      195,
    >>),
    asm.Label("rt:allocate"),
    // RDI is an already aligned, positive object size. RAX is the result.
    asm.Bytes(<<76, 137, 248, 73, 1, 255>>),
    asm.Relative(<<15, 130>>, "rt:oom"),
    asm.Bytes(<<77, 57, 247>>),
    asm.Relative(<<15, 135>>, "rt:oom"),
    asm.Bytes(<<195>>),
    asm.Label("rt:oom"),
    asm.Bytes(<<191, 71, 0, 0, 0, 184, 60, 0, 0, 0, 15, 5>>),
  ]
}
