// Owned straight-line machine plan. No calls or arbitrary byte instructions can
// enter this region; surrounding code receives only its final RAX value.
import native/ast as a
import native/check as t
import native/core as c

pub type Register {
  Rax
  Rcx
  Rdx
  // Reserved spill-recovery scratch, never part of the allocation pool.
  Rdi
  Flags
}

pub type Operator {
  Add
  Subtract
  Multiply
}

pub type Instruction {
  Constant(target: Register, value: Int)
  ReadLocal(target: Register, name: String)
  Copy(source: Register, target: Register)
  Push(Register)
  Pop(Register)
  Calculate(operator: Operator, right: Register, target: Register)
  Negate(Register)
  OverflowGuard
}

type Tree {
  Literal(Int)
  Local(String)
  Unary(Tree)
  Binary(Operator, Tree, Tree)
}

// Unsupported regions retain the existing lowering, not an inferred clobber set.
pub fn plan(value: t.Typed) -> Result(List(Instruction), String) {
  use tree <- c.then(recognize(value))
  use code <- c.then(allocate(tree, [Rax, Rcx, Rdx]))
  Ok(eliminate_dead_moves(code))
}

fn recognize(value: t.Typed) -> Result(Tree, String) {
  case value.type_ {
    a.Integer ->
      case value.node {
        t.IntegerNode(n) -> Ok(Literal(n))
        t.VariableNode(name) -> Ok(Local(name))
        // A single-expression block is grouping, with no local lifetime or
        // effect boundary. Any binding/multiple-statement block stays outside.
        t.BlockNode([t.Evaluate(child)]) -> recognize(child)
        t.UnaryNode("-", child) -> {
          use child <- c.then(recognize(child))
          Ok(Unary(child))
        }
        t.BinaryNode(op, left, right) -> {
          use operator <- c.then(case op {
            "+" -> Ok(Add)
            "-" -> Ok(Subtract)
            "*" -> Ok(Multiply)
            _ -> Error("Outside the call-free integer region")
          })
          use left <- c.then(recognize(left))
          use right <- c.then(recognize(right))
          Ok(Binary(operator, left, right))
        }
        _ -> Error("Outside the call-free integer region")
      }
    _ -> Error("Outside the call-free integer region")
  }
}

fn allocate(
  tree: Tree,
  available: List(Register),
) -> Result(List(Instruction), String) {
  case available {
    [] -> Error("Outside the call-free integer region")
    [target, ..remaining] ->
      case tree {
        Literal(n) -> Ok([Constant(target, n)])
        Local(name) -> Ok([ReadLocal(target, name)])
        Unary(child) -> {
          use code <- c.then(allocate(child, available))
          Ok(c.append(code, [Negate(target), OverflowGuard]))
        }
        Binary(op, left, right) -> {
          // Preserve left-to-right evaluation and each immediate overflow trap.
          use lhs <- c.then(allocate(left, available))
          case remaining {
            [rhs, ..] -> {
              use right_code <- c.then(allocate(right, remaining))
              Ok(c.append(
                lhs,
                c.append(right_code, [
                  Calculate(op, rhs, target),
                  OverflowGuard,
                ]),
              ))
            }
            [] -> {
              use right_code <- c.then(allocate(right, available))
              Ok(
                c.append(lhs, [
                  Push(target),
                  ..c.append(right_code, [
                    Pop(Rdi),
                    Calculate(op, target, Rdi),
                    OverflowGuard,
                    Copy(Rdi, target),
                  ])
                ]),
              )
            }
          }
        }
      }
  }
}

pub fn uses(instruction: Instruction) -> List(Register) {
  case instruction {
    Constant(_, _) | ReadLocal(_, _) | Pop(_) -> []
    Copy(source, _) | Push(source) | Negate(source) -> [source]
    Calculate(_, right, target) -> [right, target]
    OverflowGuard -> [Flags]
  }
}

pub fn definitions(instruction: Instruction) -> List(Register) {
  case instruction {
    Constant(target, _)
    | ReadLocal(target, _)
    | Copy(_, target)
    | Pop(target) -> [target]
    Negate(target) | Calculate(_, _, target) -> [target, Flags]
    Push(_) | OverflowGuard -> []
  }
}

fn member(register: Register, registers: List(Register)) -> Bool {
  case registers {
    [] -> False
    [head, ..tail] -> register == head || member(register, tail)
  }
}

fn without(
  registers: List(Register),
  removed: List(Register),
) -> List(Register) {
  case registers {
    [] -> []
    [head, ..tail] ->
      case member(head, removed) {
        True -> without(tail, removed)
        False -> [head, ..without(tail, removed)]
      }
  }
}

fn union(left: List(Register), right: List(Register)) -> List(Register) {
  case left {
    [] -> right
    [head, ..tail] ->
      case member(head, right) {
        True -> union(tail, right)
        False -> union(tail, [head, ..right])
      }
  }
}

// Straight-line liveness: live-in = uses U (live-out - definitions).
// OverflowGuard's only branch exits the process; its continuing edge is linear.
pub fn live_before(
  instruction: Instruction,
  live_after: List(Register),
) -> List(Register) {
  union(uses(instruction), without(live_after, definitions(instruction)))
}

pub fn eliminate_dead_moves(code: List(Instruction)) -> List(Instruction) {
  retain(c.reverse(code), [Rax], [])
}

fn retain(
  reversed: List(Instruction),
  live: List(Register),
  kept: List(Instruction),
) -> List(Instruction) {
  case reversed {
    [] -> kept
    [instruction, ..rest] -> {
      let removable = case instruction {
        Constant(target, _) | ReadLocal(target, _) -> !member(target, live)
        Copy(source, target) -> source == target || !member(target, live)
        // Never discard a trap or unbalance the machine stack.
        _ -> False
      }
      case removable {
        True -> retain(rest, live, kept)
        False ->
          retain(rest, live_before(instruction, live), [instruction, ..kept])
      }
    }
  }
}
