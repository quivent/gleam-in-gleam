fn sum(xs: List(Int)) -> Int {
  case xs {
    [] -> 0
    [head, ..tail] -> head + sum(tail)
  }
}

fn reverse(xs: List(Int), acc: List(Int)) -> List(Int) {
  case xs {
    [] -> acc
    [head, ..tail] -> reverse(tail, [head, ..acc])
  }
}

pub fn main() -> Nil {
  let original = [1, 2, 3]
  let reversed = reverse(original, [])
  let pair = #(sum(original), reversed)
  let #(total, items) = pair
  echo total
  echo case items {
    [] -> 0
    [head, ..] -> head
  }
  echo pair.0
  echo sum(original)
  Nil
}
