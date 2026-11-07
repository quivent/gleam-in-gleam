type Pair(a) {
  Pair(first: a, second: a)
}

pub fn main() -> Nil {
  let original = Pair(3, 4)
  let updated = Pair(..original, second: 7)
  let changed = Pair(..original, first: True, second: False)
  echo original.first
  echo updated.second
  echo changed.first
  Nil
}
