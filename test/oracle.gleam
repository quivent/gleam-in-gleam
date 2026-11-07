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

type Tree {
  Leaf(Int)
  Fork(Tree, Tree)
}

type NumberOption {
  Absent
  Present(Int)
}

type Wrapper {
  Wrap(#(Int, List(Int)))
}

fn tree_sum(tree: Tree) -> Int {
  case tree {
    Leaf(n) -> n
    Fork(left, right) -> tree_sum(left) + tree_sum(right)
  }
}

fn tree_depth(tree: Tree) -> Int {
  case tree {
    Leaf(_) -> 1
    Fork(left, right) -> {
      let a = tree_depth(left)
      let b = tree_depth(right)
      case a > b {
        True -> a + 1
        False -> b + 1
      }
    }
  }
}

pub fn custom_tree(n: Int) -> Int {
  let tree = Fork(Leaf(n), Fork(Leaf(n + 1), Leaf(n + 2)))
  tree_sum(tree) * 10 + tree_depth(tree)
}

pub fn custom_option(n: Int) -> Int {
  let value = case n == 0 {
    True -> Absent
    False -> Present(n)
  }
  case value {
    Present(0) -> -1
    Absent -> 0
    Present(other) -> other * 2
  }
}

pub fn custom_destructure(n: Int) -> Int {
  let Wrap(#(first, tail)) = Wrap(#(n, [n + 1, n + 2]))
  first + list_sum(tail)
}

pub fn custom_nested(n: Int) -> Int {
  let trees = [Leaf(n), Fork(Leaf(n + 1), Leaf(n + 2))]
  case trees {
    [Fork(_, _), ..] -> -1
    [Leaf(first), Fork(Leaf(second), Leaf(third))] ->
      first * 100 + second * 10 + third
    _ -> -2
  }
}

pub fn custom_known(n: Int) -> Int {
  let value: NumberOption = Present(n)
  let Present(x) = value
  case value {
    Present(y) -> x + y
  }
}

type Result {
  Ok(Int)
  Error(String)
}

pub fn custom_result(n: Int) -> Int {
  let result = case n == 0 {
    True -> Error("missing")
    False -> Ok(n)
  }
  case result {
    Error(_) -> -1
    Ok(value) -> value
  }
}

pub type PublicValue {
  PublicValue(Int)
}

pub fn public_make(n: Int) -> PublicValue {
  PublicValue(n)
}

pub fn custom_public(n: Int) -> Int {
  let PublicValue(value) = public_make(n)
  value
}

type Maybe(a) {
  None
  Just(a)
}

fn maybe_int(value: Maybe(Int), fallback: Int) -> Int {
  case value {
    None -> fallback
    Just(n) -> n
  }
}

pub fn generic_maybe(n: Int) -> Int {
  let value: Maybe(Int) = case n == 0 {
    True -> None
    False -> Just(n)
  }
  maybe_int(value, 17)
}

pub fn generic_bool(n: Int) -> Bool {
  let value = Just(n > 0)
  case value {
    Just(b) -> b
  }
}

type Duo(a, b) {
  Duo(a, b)
}

pub fn generic_duo(n: Int) -> Int {
  let Duo(number, flag) = Duo(n, n > 0)
  case flag {
    True -> number + 1
    False -> number - 1
  }
}

type Same(a) {
  Same(a, a)
}

pub fn generic_same(n: Int) -> Int {
  let Same(first, second) = Same([], [n])
  list_sum(first) + list_sum(second)
}

type Rose(a) {
  Bud(a)
  Branch(List(Rose(a)))
}

fn rose_sum(tree: Rose(Int)) -> Int {
  case tree {
    Bud(n) -> n
    Branch(children) -> rose_list_sum(children)
  }
}

fn rose_list_sum(children: List(Rose(Int))) -> Int {
  case children {
    [] -> 0
    [head, ..tail] -> rose_sum(head) + rose_list_sum(tail)
  }
}

pub fn generic_recursive(n: Int) -> Int {
  rose_sum(Branch([Bud(n), Branch([Bud(n + 1), Bud(n + 2)])]))
}

type Phantom(a) {
  Marker(Int)
}

pub fn generic_phantom(n: Int) -> Int {
  let marker: Phantom(String) = Marker(n)
  let Marker(value) = marker
  value
}

type LabelBox(a) {
  LabelBox(value: a, count: Int)
}

pub fn labelled_generic(n: Int) -> Int {
  let box = LabelBox(count: n + 1, value: n)
  box.value + box.count
}

pub fn labelled_pattern(n: Int) -> Int {
  let box = LabelBox(value: n, count: n + 1)
  let LabelBox(count: b, value: a) = box
  a * 10 + b
}

pub fn labelled_spread(n: Int) -> Int {
  labelled_spread_value(LabelBox(value: n, count: n + 1))
}

fn labelled_spread_value(box: LabelBox(Int)) -> Int {
  case box {
    LabelBox(count: result, ..) -> result
  }
}

pub fn labelled_shorthand(n: Int) -> Int {
  let value = n
  let count = n + 1
  let LabelBox(value:, count:) = LabelBox(count:, value:)
  value + count
}

type Message(a) {
  First(value: a, flag: Bool)
  Second(value: a, marker: Int)
}

fn message_value(message: Message(Int)) -> Int {
  message.value
}

pub fn labelled_common(n: Int) -> Int {
  message_value(First(n, True)) + message_value(Second(marker: 3, value: n + 1))
}

pub type VariantValue {
  WithValue(value: Int)
  NoValue
}

pub fn labelled_known(n: Int) -> Int {
  let value = WithValue(n)
  value.value
}
