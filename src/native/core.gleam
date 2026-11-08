// Compiler-owned utilities. No standard-library or third-party imports.
pub fn then(
  value: Result(a, String),
  f: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case value {
    Ok(x) -> f(x)
    Error(e) -> Error(e)
  }
}

pub fn reverse(xs: List(a)) -> List(a) {
  reverse_into(xs, [])
}

fn reverse_into(xs: List(a), acc: List(a)) -> List(a) {
  case xs {
    [] -> acc
    [x, ..rest] -> reverse_into(rest, [x, ..acc])
  }
}

pub fn append(xs: List(a), ys: List(a)) -> List(a) {
  // Both traversals are direct tail calls in bootstrap JS. Constructing the
  // result after a recursive call overflows on the compiler's full code stream.
  reverse_into(reverse(xs), ys)
}

pub fn length(xs: List(a)) -> Int {
  count(xs, 0)
}

pub fn nth(xs: List(a), index: Int) -> Result(a, String) {
  case xs, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> nth(rest, n - 1)
    _, _ -> Error("Tuple index out of bounds")
  }
}

pub fn join(xs: List(String), separator: String) -> String {
  case xs {
    [] -> ""
    [s] -> s
    [s, ..rest] -> s <> separator <> join(rest, separator)
  }
}

pub fn uppercase_name(name: String) -> Bool {
  case name {
    "A" <> _
    | "B" <> _
    | "C" <> _
    | "D" <> _
    | "E" <> _
    | "F" <> _
    | "G" <> _
    | "H" <> _
    | "I" <> _
    | "J" <> _
    | "K" <> _
    | "L" <> _
    | "M" <> _
    | "N" <> _
    | "O" <> _
    | "P" <> _
    | "Q" <> _
    | "R" <> _
    | "S" <> _
    | "T" <> _
    | "U" <> _
    | "V" <> _
    | "W" <> _
    | "X" <> _
    | "Y" <> _
    | "Z" <> _ -> True
    _ -> False
  }
}

pub fn discarded_name(name: String) -> Bool {
  case name {
    "_" <> _ -> True
    _ -> False
  }
}

fn count(xs: List(a), n: Int) -> Int {
  case xs {
    [] -> n
    [_, ..rest] -> count(rest, n + 1)
  }
}

pub fn map(xs: List(a), f: fn(a) -> b) -> List(b) {
  case xs {
    [] -> []
    [x, ..rest] -> [f(x), ..map(rest, f)]
  }
}

pub fn try_map(
  xs: List(a),
  f: fn(a) -> Result(b, String),
) -> Result(List(b), String) {
  case xs {
    [] -> Ok([])
    [x, ..rest] ->
      case f(x) {
        Error(e) -> Error(e)
        Ok(value) ->
          case try_map(rest, f) {
            Error(e) -> Error(e)
            Ok(values) -> Ok([value, ..values])
          }
      }
  }
}

// Validation consumes outcomes directly, retaining only the first failure.
// Do not allocate a list of successful values that the caller discards.
pub fn try_each(
  xs: List(a),
  f: fn(a) -> Result(b, String),
) -> Result(Nil, String) {
  case xs {
    [] -> Ok(Nil)
    [x, ..rest] ->
      case f(x) {
        Error(e) -> Error(e)
        Ok(_) -> try_each(rest, f)
      }
  }
}

// Search existing immutable nodes; do not materialize a parallel key/value list.
pub fn find(xs: List(a), predicate: fn(a) -> Bool) -> Result(a, String) {
  case xs {
    [] -> Error("Item not found")
    [x, ..rest] ->
      case predicate(x) {
        True -> Ok(x)
        False -> find(rest, predicate)
      }
  }
}

pub fn lookup(xs: List(#(String, a)), name: String) -> Result(a, String) {
  case xs {
    [] -> Error("Unknown name: " <> name)
    [#(key, value), ..rest] ->
      case key == name {
        True -> Ok(value)
        False -> lookup(rest, name)
      }
  }
}

pub fn put(
  xs: List(#(String, a)),
  key: String,
  value: a,
) -> List(#(String, a)) {
  case xs {
    [] -> [#(key, value)]
    [#(name, old), ..rest] ->
      case name == key {
        True -> [#(key, value), ..rest]
        False -> [#(name, old), ..put(rest, key, value)]
      }
  }
}

pub fn decimal(n: Int) -> String {
  case n < 0 {
    True -> "-" <> decimal(0 - n)
    False ->
      case n < 10 {
        True -> character(n + 48)
        False -> decimal(n / 10) <> character(n % 10 + 48)
      }
  }
}

pub fn character(n: Int) -> String {
  case n {
    48 -> "0"
    49 -> "1"
    50 -> "2"
    51 -> "3"
    52 -> "4"
    53 -> "5"
    54 -> "6"
    55 -> "7"
    56 -> "8"
    57 -> "9"
    65 -> "A"
    66 -> "B"
    67 -> "C"
    68 -> "D"
    69 -> "E"
    70 -> "F"
    71 -> "G"
    72 -> "H"
    73 -> "I"
    74 -> "J"
    75 -> "K"
    76 -> "L"
    77 -> "M"
    78 -> "N"
    79 -> "O"
    80 -> "P"
    81 -> "Q"
    82 -> "R"
    83 -> "S"
    84 -> "T"
    85 -> "U"
    86 -> "V"
    87 -> "W"
    88 -> "X"
    89 -> "Y"
    90 -> "Z"
    97 -> "a"
    98 -> "b"
    99 -> "c"
    100 -> "d"
    101 -> "e"
    102 -> "f"
    103 -> "g"
    104 -> "h"
    105 -> "i"
    106 -> "j"
    107 -> "k"
    108 -> "l"
    109 -> "m"
    110 -> "n"
    111 -> "o"
    112 -> "p"
    113 -> "q"
    114 -> "r"
    115 -> "s"
    116 -> "t"
    117 -> "u"
    118 -> "v"
    119 -> "w"
    120 -> "x"
    121 -> "y"
    122 -> "z"
    95 -> "_"
    _ -> "?"
  }
}

pub fn concat(xs: List(BitArray)) -> BitArray {
  // Merge adjacent chunks in rounds. Each payload is copied O(log chunks)
  // times, rather than copying the entire growing prefix for every chunk.
  case xs {
    [] -> <<>>
    [only] -> only
    _ -> concat(concat_round(xs, []))
  }
}

fn concat_round(
  xs: List(BitArray),
  reversed: List(BitArray),
) -> List(BitArray) {
  case xs {
    [] -> reverse(reversed)
    [only] -> reverse([only, ..reversed])
    [left, right, ..rest] ->
      concat_round(rest, [<<left:bits, right:bits>>, ..reversed])
  }
}

pub fn bytes(xs: List(Int)) -> BitArray {
  concat(map(xs, fn(x) { <<x:8>> }))
}

pub fn byte_length(value: BitArray) -> Int {
  byte_count(value, 0)
}

fn byte_count(value: BitArray, n: Int) -> Int {
  case value {
    <<_, rest:bits>> -> byte_count(rest, n + 1)
    _ -> n
  }
}
