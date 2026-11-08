import native/core as c

pub type Part {
  Bytes(BitArray)
  Label(String)
  Relative(opcode: BitArray, target: String)
  // Ordered immutable instruction span; no bytes or labels are copied to join it.
  Span(List(Part))
}

// Preserve small prefixes directly; retain longer already-planned sequences.
pub fn join(left: List(Part), right: List(Part)) -> List(Part) {
  case right {
    [] -> left
    _ ->
      case left {
        [] -> right
        [first] -> [first, ..right]
        [first, second] -> [first, second, ..right]
        _ -> [Span(left), ..right]
      }
  }
}

pub fn assemble(parts: List(Part)) -> Result(BitArray, String) {
  use labels <- c.then(locate(parts, 0, [], []))
  use chunks <- c.then(emit(parts, 0, labels, [], []))
  Ok(c.concat(chunks))
}

// Exact byte offsets for development traces and instruction-level qualification.
// Labels emit no bytes; the normal assembler remains the sole byte emitter.
pub fn symbols(parts: List(Part)) -> Result(List(#(String, Int)), String) {
  locate(parts, 0, [], [])
}

fn locate(
  parts: List(Part),
  offset: Int,
  labels: List(#(String, Int)),
  pending: List(List(Part)),
) -> Result(List(#(String, Int)), String) {
  case parts {
    [] ->
      case pending {
        [] -> Ok(labels)
        [next, ..tail] -> locate(next, offset, labels, tail)
      }
    [Span(inner), ..rest] -> locate(inner, offset, labels, [rest, ..pending])
    [Label(name), ..rest] ->
      case c.lookup(labels, name) {
        Ok(_) -> Error("Duplicate assembly label: " <> name)
        Error(_) -> locate(rest, offset, [#(name, offset), ..labels], pending)
      }
    [Bytes(bytes), ..rest] ->
      locate(rest, offset + c.byte_length(bytes), labels, pending)
    [Relative(opcode, _), ..rest] ->
      locate(rest, offset + c.byte_length(opcode) + 4, labels, pending)
  }
}

fn emit(
  parts: List(Part),
  offset: Int,
  labels: List(#(String, Int)),
  reversed: List(BitArray),
  pending: List(List(Part)),
) -> Result(List(BitArray), String) {
  case parts {
    [] ->
      case pending {
        [] -> Ok(c.reverse(reversed))
        [next, ..tail] -> emit(next, offset, labels, reversed, tail)
      }
    [Span(inner), ..rest] ->
      emit(inner, offset, labels, reversed, [rest, ..pending])
    [Label(_), ..rest] -> emit(rest, offset, labels, reversed, pending)
    [Bytes(bytes), ..rest] ->
      emit(
        rest,
        offset + c.byte_length(bytes),
        labels,
        [bytes, ..reversed],
        pending,
      )
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
              emit(
                rest,
                next,
                labels,
                [<<opcode:bits, displacement:32-little>>, ..reversed],
                pending,
              )
          }
        }
      }
    }
  }
}
