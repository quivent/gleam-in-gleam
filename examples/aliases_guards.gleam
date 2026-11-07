type Count =
  Int

type Pair(a) =
  #(a, a)

fn choose(pair: Pair(Count)) -> Count {
  case pair {
    #(a, b) if a > b -> a
    #(_, b) -> b
  }
}

pub fn main() -> Nil {
  echo choose(#(7, 4))
  echo choose(#(2, 5))
  let limit = 4
  let accepts = fn(n: Count) {
    case n {
      value if value > limit -> True
      _ -> False
    }
  }
  echo accepts(5)
  echo accepts(3)
  Nil
}
