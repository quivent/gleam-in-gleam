// Dev-only machine-code probes of the allocator's actual boundary behavior.
import native/assembler as asm
import native/core
import native/elf
import native/heap

pub fn probe(exhaust: Bool) -> Result(BitArray, String) {
  let entry = [
    asm.Relative(<<232>>, "rt:heap_init"),
    asm.Bytes(<<191, 0, 0, 0, 4>>),
    asm.Relative(<<232>>, "rt:allocate"),
  ]
  let overflow = case exhaust {
    False -> []
    True -> [
      asm.Bytes(<<191, 8, 0, 0, 0>>),
      asm.Relative(<<232>>, "rt:allocate"),
    ]
  }
  let exit = [asm.Bytes(<<49, 255, 184, 60, 0, 0, 0, 15, 5>>)]
  let parts =
    core.append(entry, core.append(overflow, core.append(exit, heap.runtime())))
  use machine <- core.then(asm.assemble(parts))
  Ok(elf.executable(machine))
}
