type Tree {
  Leaf(Int)
  Fork(Tree, Tree)
}

type Door {
  Closed
  Open(Int)
}

fn sum(tree: Tree) -> Int {
  case tree {
    Leaf(n) -> n
    Fork(left, right) -> sum(left) + sum(right)
  }
}

pub fn main() -> Nil {
  let tree = Fork(Leaf(2), Leaf(3))
  echo sum(tree)
  echo case tree {
    Fork(Leaf(a), Leaf(b)) -> a * 10 + b
    _ -> 0
  }
  let door = Closed
  echo case door {
    Open(n) -> n
    Closed -> 0
  }
  Nil
}
