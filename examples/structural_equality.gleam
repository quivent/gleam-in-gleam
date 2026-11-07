type Tree {
  Empty
  Leaf(Int, String)
  Branch(List(Tree))
}

pub fn main() -> Nil {
  echo Branch([Leaf(7, "λ" <> "β")]) == Branch([Leaf(7, "λβ")])
  echo Empty == Leaf(7, "x")
  echo [1, 2, 3] != [1, 2, 4]
  echo <<1, 2>> == <<1, 2>>
  Nil
}
