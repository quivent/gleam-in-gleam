// Validate scalar UTF-8 without a library: reject overlong encodings, surrogate
// code points, out-of-range scalars and truncated sequences.
pub fn valid(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<a, rest:bits>> if a <= 127 -> valid(rest)
    <<a, b, rest:bits>> if a >= 194 && a <= 223 && b >= 128 && b <= 191 ->
      valid(rest)
    <<224, b, c, rest:bits>> if b >= 160 && b <= 191 && c >= 128 && c <= 191 ->
      valid(rest)
    <<a, b, c, rest:bits>>
      if { a >= 225 && a <= 236 || a >= 238 && a <= 239 }
      && b >= 128
      && b <= 191
      && c >= 128
      && c <= 191
    -> valid(rest)
    <<237, b, c, rest:bits>> if b >= 128 && b <= 159 && c >= 128 && c <= 191 ->
      valid(rest)
    <<240, b, c, d, rest:bits>>
      if b >= 144 && b <= 191 && c >= 128 && c <= 191 && d >= 128 && d <= 191
    -> valid(rest)
    <<a, b, c, d, rest:bits>>
      if a >= 241
      && a <= 243
      && b >= 128
      && b <= 191
      && c >= 128
      && c <= 191
      && d >= 128
      && d <= 191
    -> valid(rest)
    <<244, b, c, d, rest:bits>>
      if b >= 128 && b <= 143 && c >= 128 && c <= 191 && d >= 128 && d <= 191
    -> valid(rest)
    _ -> False
  }
}
