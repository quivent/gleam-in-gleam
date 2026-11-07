// Byte-aligned subset, normalized before native lowering. Reject unsupported
// sizes/options rather than silently changing segment semantics.
import native/ast as a
import native/core as c

pub fn mode(
  options: List(a.BitOption),
  pattern: Bool,
) -> Result(a.BitMode, String) {
  case options {
    [a.BitName("utf8")] ->
      case pattern {
        True -> Error("UTF-8 codepoint patterns are not implemented yet")
        False -> Ok(a.Utf8Segment)
      }
    _ -> integer_mode(options, pattern)
  }
}

fn integer_mode(
  options: List(a.BitOption),
  pattern: Bool,
) -> Result(a.BitMode, String) {
  use _ <- c.then(usage(options, pattern))
  use #(width, little, signed, bits) <- c.then(
    read(options, 8, False, False, False, []),
  )
  case bits {
    True ->
      case options {
        [a.BitName("bytes")] -> Ok(a.BytesSegment)
        _ -> Ok(a.BitsSegment)
      }
    False ->
      case
        width >= 0 && width <= 64 && width % 8 == 0 && { !pattern || width > 0 }
      {
        True -> Ok(a.IntegerSegment(width / 8, little, signed))
        False ->
          Error(
            "Native seed supports only byte-aligned integer segments of 0..64 bits",
          )
      }
  }
}

fn read(
  options: List(a.BitOption),
  width: Int,
  little: Bool,
  signed: Bool,
  bits: Bool,
  seen: List(#(String, Nil)),
) -> Result(#(Int, Bool, Bool, Bool), String) {
  case options {
    [] ->
      case bits && c.length(seen) != 1 {
        True ->
          Error(
            "Bit-array concatenation options cannot be combined with integer options",
          )
        False -> Ok(#(width, little, signed, bits))
      }
    [option, ..rest] -> {
      use #(key, width, little, signed, bits) <- c.then(case option {
        a.BitSize(n) -> Ok(#("size", n, little, signed, bits))
        a.BitName("int") -> Ok(#("kind", width, little, signed, False))
        a.BitName("bits") | a.BitName("bytes") ->
          Ok(#("kind", width, little, signed, True))
        a.BitName("little") -> Ok(#("endian", width, True, signed, bits))
        a.BitName("big") -> Ok(#("endian", width, False, signed, bits))
        a.BitName("signed") -> Ok(#("sign", width, little, True, bits))
        a.BitName("unsigned") -> Ok(#("sign", width, little, False, bits))
        a.BitName(name) -> Error("Bit-array option not implemented: " <> name)
      })
      use _ <- c.then(case c.lookup(seen, key) {
        Ok(_) -> Error("Duplicate/conflicting bit-array option")
        Error(_) -> Ok(Nil)
      })
      read(rest, width, little, signed, bits, [#(key, Nil), ..seen])
    }
  }
}

fn usage(options: List(a.BitOption), pattern: Bool) -> Result(Nil, String) {
  case options {
    [] -> Ok(Nil)
    [a.BitName(name), ..]
      if !pattern
      && { name == "bytes" || name == "signed" || name == "unsigned" }
    -> Error("Bit-array option is only valid in patterns: " <> name)
    [_, ..rest] -> usage(rest, pattern)
  }
}
