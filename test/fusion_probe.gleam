// Native execution checks: independently known relocation bytes and collisions.
import native/assembler as asm
import native/core

pub fn main() -> Nil {
  let jump = fn(name: String) { asm.Relative(<<233>>, name) }
  let parts = [
    jump("B@"),
    asm.Label("Aa"),
    asm.Bytes(<<144>>),
    asm.Label("B@"),
    jump("Aa"),
  ]
  echo case asm.assemble(parts) {
    Ok(bytes) -> bytes == <<233, 1:32-little, 144, 233, -6:32-little>>
    Error(_) -> False
  }
  echo case asm.assemble([asm.Label("Aa"), asm.Label("B@"), asm.Label("Aa")]) {
    Error(message) -> message == "Duplicate assembly label: Aa"
    Ok(_) -> False
  }
  echo case asm.assemble([jump("first"), asm.Span([jump("last")])]) {
    Error(message) -> message == "Unknown name: first"
    Ok(_) -> False
  }
  echo case asm.assemble([asm.Label("λ😀"), asm.Bytes(<<144>>), jump("λ😀")]) {
    Ok(bytes) -> bytes == <<144, 233, -6:32-little>>
    Error(_) -> False
  }
  let outcome =
    core.try_each([1, 2, 3], fn(n: Int) {
      echo n
      case n == 2 {
        True -> Error("first failure")
        False -> Ok(n)
      }
    })
  echo case outcome {
    Error(message) -> message == "first failure"
    Ok(_) -> False
  }
  Nil
}
