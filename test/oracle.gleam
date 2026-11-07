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

pub fn list_sum(xs: List(Int)) -> Int {
  case xs {
    [] -> 0
    [head, ..tail] -> head + list_sum(tail)
  }
}

pub fn reverse_list(xs: List(Int), acc: List(Int)) -> List(Int) {
  case xs {
    [] -> acc
    [head, ..tail] -> reverse_list(tail, [head, ..acc])
  }
}

pub fn list_work(n: Int) -> Int {
  let original = [n, n + 1, n + 2]
  let reversed = reverse_list(original, [])
  case reversed {
    [first, second, third] ->
      first * 100 + second * 10 + third + list_sum(original)
    _ -> -1
  }
}

pub fn tuple_work(n: Int) -> Int {
  let pair = #(n, #(n + 1, n + 2))
  let #(a, #(b, c)) = pair
  a + b * 10 + c * 100 + pair.1.0
}

pub fn nested_pattern(n: Int) -> Int {
  let items = [#(True, [n]), #(False, [])]
  case items {
    [#(False, _), ..] -> -1
    [#(True, [value]), #(False, [])] -> value
    _ -> -2
  }
}

pub fn choose_list(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> [n, n + 1]
  }
}

pub fn chosen_list_sum(n: Int) -> Int {
  list_sum(choose_list(n))
}
