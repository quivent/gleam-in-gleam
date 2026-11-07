fn pick(a: Int, b: Int) -> Int {
  case a, b {
    n, 0 | 0, n -> n
    _, _ -> 99
  }
}

fn guarded(a: Int, b: Int) -> Int {
  case a, b {
    n, _ | _, n if n > 5 -> n
    _, _ -> 0
  }
}

fn flags(a: Bool, b: Bool) -> Int {
  case a, b {
    True, True -> 1
    True, False -> 2
    False, True -> 3
    False, False -> 4
  }
}

pub fn main() -> Nil {
  echo pick(0, 7)
  echo guarded(1, 9)
  echo flags(False, True)
  Nil
}
