type Item {
  Value(value: Int)
  Empty
}

fn total(item: Item) -> Int {
  case item {
    Value(n) as whole -> n + whole.value
    Empty -> 0
  }
}

pub fn main() -> Nil {
  echo total(Value(7))
  let #(x, y) as pair = #(3, 4)
  echo x + y + pair.0
  Nil
}
