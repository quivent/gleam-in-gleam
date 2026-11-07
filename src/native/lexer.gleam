import native/core

pub type Kind {
  Word(String)
  Number(Int)
  Text(BitArray)
  Symbol(String)
  End
}

pub type Token {
  Token(kind: Kind, offset: Int)
}

pub fn lex(source: BitArray) -> Result(List(Token), String) {
  scan(source, 0, [])
}

fn fail(offset: Int, message: String) -> Result(a, String) {
  Error("byte " <> core.decimal(offset) <> ": " <> message)
}

fn scan(
  source: BitArray,
  offset: Int,
  acc: List(Token),
) -> Result(List(Token), String) {
  case source {
    <<>> -> Ok(core.reverse([Token(End, offset), ..acc]))
    <<c, rest:bits>> if c == 32 || c == 9 || c == 10 || c == 13 ->
      scan(rest, offset + 1, acc)
    <<47, 47, rest:bits>> -> {
      let #(remaining, at) = comment(rest, offset + 2)
      scan(remaining, at, acc)
    }
    <<34, rest:bits>> ->
      case quoted(rest, offset + 1, <<>>) {
        Error(e) -> Error(e)
        Ok(#(value, remaining, at)) ->
          scan(remaining, at, [Token(Text(value), offset), ..acc])
      }
    <<c, _:bits>> if c >= 48 && c <= 57 ->
      case number(source, offset, 0, False) {
        Error(e) -> Error(e)
        Ok(#(value, rest, at)) ->
          scan(rest, at, [Token(Number(value), offset), ..acc])
      }
    <<c, _:bits>> if c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 -> {
      let #(name, rest, at) = identifier(source, offset, "")
      scan(rest, at, [Token(Word(name), offset), ..acc])
    }
    <<45, 62, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("->"), offset), ..acc])
    <<61, 61, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("=="), offset), ..acc])
    <<33, 61, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("!="), offset), ..acc])
    <<60, 61, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("<="), offset), ..acc])
    <<62, 61, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol(">="), offset), ..acc])
    <<38, 38, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("&&"), offset), ..acc])
    <<124, 124, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("||"), offset), ..acc])
    <<124, 62, rest:bits>> ->
      scan(rest, offset + 2, [Token(Symbol("|>"), offset), ..acc])
    <<c, rest:bits>> ->
      case punctuation(c) {
        Error(_) -> fail(offset, "Unsupported character " <> core.decimal(c))
        Ok(symbol) ->
          scan(rest, offset + 1, [Token(Symbol(symbol), offset), ..acc])
      }
    _ -> fail(offset, "Source is not byte aligned")
  }
}

fn comment(source: BitArray, offset: Int) -> #(BitArray, Int) {
  case source {
    <<10, _:bits>> | <<>> -> #(source, offset)
    <<_, rest:bits>> -> comment(rest, offset + 1)
    _ -> #(source, offset)
  }
}

fn identifier(
  source: BitArray,
  offset: Int,
  acc: String,
) -> #(String, BitArray, Int) {
  case source {
    <<c, rest:bits>>
      if c >= 65
      && c <= 90
      || c >= 97
      && c <= 122
      || c >= 48
      && c <= 57
      || c == 95
    -> identifier(rest, offset + 1, acc <> core.character(c))
    _ -> #(acc, source, offset)
  }
}

fn number(
  source: BitArray,
  offset: Int,
  acc: Int,
  seen: Bool,
) -> Result(#(Int, BitArray, Int), String) {
  case source {
    <<c, rest:bits>> if c >= 48 && c <= 57 ->
      case acc > 214_748_364 || acc == 214_748_364 && c > 55 {
        True ->
          fail(
            offset,
            "Integer literal outside seed compiler's 32-bit literal range",
          )
        False -> number(rest, offset + 1, acc * 10 + c - 48, True)
      }
    <<95, rest:bits>> if seen -> number(rest, offset + 1, acc, seen)
    _ -> Ok(#(acc, source, offset))
  }
}

fn quoted(
  source: BitArray,
  offset: Int,
  acc: BitArray,
) -> Result(#(BitArray, BitArray, Int), String) {
  case source {
    <<>> -> fail(offset, "Unterminated string")
    <<34, rest:bits>> -> Ok(#(acc, rest, offset + 1))
    <<92, c, rest:bits>> ->
      case c {
        110 -> quoted(rest, offset + 2, <<acc:bits, 10>>)
        114 -> quoted(rest, offset + 2, <<acc:bits, 13>>)
        116 -> quoted(rest, offset + 2, <<acc:bits, 9>>)
        34 | 92 -> quoted(rest, offset + 2, <<acc:bits, c>>)
        _ -> fail(offset, "Unsupported string escape")
      }
    <<c, rest:bits>> -> quoted(rest, offset + 1, <<acc:bits, c>>)
    _ -> fail(offset, "String is not byte aligned")
  }
}

fn punctuation(c: Int) -> Result(String, Nil) {
  case c {
    40 -> Ok("(")
    41 -> Ok(")")
    123 -> Ok("{")
    125 -> Ok("}")
    44 -> Ok(",")
    58 -> Ok(":")
    61 -> Ok("=")
    43 -> Ok("+")
    45 -> Ok("-")
    42 -> Ok("*")
    47 -> Ok("/")
    37 -> Ok("%")
    60 -> Ok("<")
    62 -> Ok(">")
    33 -> Ok("!")
    124 -> Ok("|")
    91 -> Ok("[")
    93 -> Ok("]")
    35 -> Ok("#")
    46 -> Ok(".")
    64 -> Ok("@")
    _ -> Error(Nil)
  }
}
