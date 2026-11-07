fn make_adder(base: Int) -> fn(Int) -> Int {
  fn(value) { base + value }
}

fn with_value(value: a, next: fn(a) -> b) -> b {
  next(value)
}

pub fn main() -> Nil {
  let first = make_adder(10)
  let second = make_adder(20)
  echo first(2)
  echo second(2)
  let result = {
    use value <- with_value(5)
    value + 1
  }
  echo result
  Nil
}
