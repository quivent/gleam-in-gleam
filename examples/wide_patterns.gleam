fn choose(n: Int) -> Bool {
  case n {
    4_294_967_296 -> True
    _ -> False
  }
}

pub fn main() -> Nil {
  echo choose(4_294_967_296)
  echo choose(0)
  echo 9_007_199_254_740_991
  echo -2_147_483_648
  Nil
}
