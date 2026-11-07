import native/core as c

pub type Part {
  Bytes(BitArray)
  Label(String)
  Relative(opcode: BitArray, target: String)
}

pub fn assemble(parts: List(Part)) -> Result(BitArray, String) {
  use labels <- c.then(locate(parts, 0, []))
  use chunks <- c.then(emit(parts, 0, labels, []))
  Ok(c.concat(chunks))
}

fn locate(
  parts: List(Part),
  offset: Int,
  labels: List(#(String, Int)),
) -> Result(List(#(String, Int)), String) {
  case parts {
    [] -> Ok(labels)
    [Label(name), ..rest] ->
      case c.lookup(labels, name) {
        Ok(_) -> Error("Duplicate assembly label: " <> name)
        Error(_) -> locate(rest, offset, [#(name, offset), ..labels])
      }
    [Bytes(bytes), ..rest] ->
      locate(rest, offset + c.byte_length(bytes), labels)
    [Relative(opcode, _), ..rest] ->
      locate(rest, offset + c.byte_length(opcode) + 4, labels)
  }
}

fn emit(
  parts: List(Part),
  offset: Int,
  labels: List(#(String, Int)),
  reversed: List(BitArray),
) -> Result(List(BitArray), String) {
  case parts {
    [] -> Ok(c.reverse(reversed))
    [Label(_), ..rest] -> emit(rest, offset, labels, reversed)
    [Bytes(bytes), ..rest] ->
      emit(rest, offset + c.byte_length(bytes), labels, [bytes, ..reversed])
    [Relative(opcode, name), ..rest] -> {
      // Keep the recursive call direct so bootstrap JS uses a loop, rather
      // than nesting one result continuation per emitted instruction.
      case c.lookup(labels, name) {
        Error(e) -> Error(e)
        Ok(target) -> {
          let next = offset + c.byte_length(opcode) + 4
          let displacement = target - next
          case displacement < -2_147_483_648 || displacement > 2_147_483_647 {
            True -> Error("Relative relocation out of signed 32-bit range")
            False ->
              emit(rest, next, labels, [
                <<opcode:bits, displacement:32-little>>,
                ..reversed
              ])
          }
        }
      }
    }
  }
}
