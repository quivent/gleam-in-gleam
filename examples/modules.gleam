import module_demo/box as b
import module_demo/numbers

pub fn main() -> Nil {
  let original = b.Box(7, 8)
  let updated = b.Box(..original, value: numbers.twice(original.value))
  case updated {
    b.Box(value, marker) -> {
      echo value
      echo marker
      Nil
    }
  }
  let inc = numbers.increment
  echo inc(2)
  Nil
}
