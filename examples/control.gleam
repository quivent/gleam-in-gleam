fn sum(a: Int, b: Int, c: Int) -> Int {
  a + b * c
}

pub fn main() -> Nil {
  let n = sum(2, 3, 4)
  echo n
  echo case n {
    0 -> "zero"
    14 -> "fourteen"
    _ -> "other"
  }
  echo False
    && {
      echo "must not run"
      True
    }
  echo True
    || {
      echo "must not run"
      False
    }
  echo -12_345
  echo 12 / 0
  echo -17 % 5
  Nil
}
