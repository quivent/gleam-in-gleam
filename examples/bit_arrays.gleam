fn count(data: BitArray) -> Int {
  case data {
    <<>> -> 0
    <<_, rest:bits>> -> 1 + count(rest)
    _ -> 0
  }
}

pub fn main() -> Nil {
  let bytes = <<7, 8>>
  let packet = <<9, bytes:bits, -2:16-little>>
  echo count(packet)
  case packet {
    <<first, _, _, signed:16-little-signed>> -> {
      echo first
      echo signed
      Nil
    }
    _ -> Nil
  }
  case <<4660:16-little>> {
    <<value:16-little>> -> {
      echo value
      Nil
    }
    _ -> Nil
  }
  Nil
}
