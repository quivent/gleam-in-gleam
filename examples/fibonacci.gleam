fn fib(n: Int) -> Int {
  case n < 2 {
    True -> n
    False -> fib(n - 1) + fib(n - 2)
  }
}

pub fn main() -> Nil {
  echo fib(10)
  Nil
}
