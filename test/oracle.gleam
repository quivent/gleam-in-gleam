// Compiled by the unmodified upstream compiler as an independent semantic oracle.
pub fn fibonacci(n: Int) -> Int {
  case n < 2 {
    True -> n
    False -> fibonacci(n - 1) + fibonacci(n - 2)
  }
}

pub fn arithmetic(a: Int, b: Int, c: Int) -> Int {
  let x = a + b * c
  x - a / c + b % c
}

pub fn quotient(a: Int, b: Int) -> Int {
  a / b
}

pub fn remainder(a: Int, b: Int) -> Int {
  a % b
}

pub fn bool_case(a: Int, b: Int) -> Bool {
  case a < b {
    True -> !{ a == b } && True
    False -> a >= b || False
  }
}

pub fn integer_case(a: Int) -> Int {
  case a {
    -1 -> 100
    0 -> 200
    1 -> 300
    other -> other * 10
  }
}

pub fn shadow(a: Int) -> Int {
  let a = a + 1
  let inner = {
    let a = a * 3
    a + 2
  }
  a + inner
}

pub fn chosen_string(a: Int) -> String {
  case a {
    0 -> "zero"
    _ -> "Gleam → native"
  }
}

pub fn identity(a: Int) -> Int {
  a
}

pub fn constant() -> Int {
  0
}

pub fn unit() -> Nil {
  Nil
}
