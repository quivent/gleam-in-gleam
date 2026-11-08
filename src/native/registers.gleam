// Owned straight-line machine plan. Named calls have an explicit clobber and
// stack-argument contract. Surrounding code receives only the final RAX value.
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
  NamedCall(name: String, argument_count: Int)
}

type Tree {
  Literal(Int)
  Local(String)
  Unary(Tree)
  Binary(Operator, Tree, Tree)
  DirectCall(String, List(Tree))
}

// Unsupported regions retain the existing lowering, not an inferred clobber set.
pub fn plan(value: t.Typed) -> Result(List(Instruction), String) {
  use tree <- c.then(recognize(value))
  use code <- c.then(allocate(tree, pool()))
  Ok(eliminate_dead_moves(code))
}

fn pool() -> List(Register) {
  [Rax, Rcx, Rdx]
}

fn recognize(value: t.Typed) -> Result(Tree, String) {
  case value.type_ {
    a.Integer ->
      case value.node {
        t.IntegerNode(n) -> Ok(Literal(n))
        t.VariableNode(name) -> Ok(Local(name))
        t.CallNode(name, arguments) -> {
          use arguments <- c.then(recognize_arguments(arguments))
          Ok(DirectCall(name, arguments))
        }
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
            _ -> Error("Outside the supported integer region")
          })
          use left <- c.then(recognize(left))
          use right <- c.then(recognize(right))
          Ok(Binary(operator, left, right))
        }
        _ -> Error("Outside the supported integer region")
      }
    _ -> Error("Outside the supported integer region")
  }
}

fn recognize_arguments(arguments: List(t.Typed)) -> Result(List(Tree), String) {
  case arguments {
    [] -> Ok([])
    [value, ..rest] -> {
      use value <- c.then(recognize(value))
      use tail <- c.then(recognize_arguments(rest))
      Ok([value, ..tail])
    }
  }
}

fn allocate(
  tree: Tree,
  available: List(Register),
) -> Result(List(Instruction), String) {
  case available {
    [] -> Error("Outside the supported integer region")
    [target, ..remaining] ->
      case tree {
        Literal(n) -> Ok([Constant(target, n)])
        Local(name) -> Ok([ReadLocal(target, name)])
        DirectCall(name, arguments) -> {
          // The occupied prefix contains ancestor values still needed after the
          // call. Save it BEFORE evaluating arguments, which may themselves call.
          let saved = without(pool(), available)
          use arguments_code <- c.then(allocate_arguments(arguments))
          Ok(c.append(
            push_registers(saved),
            c.append(arguments_code, [
              NamedCall(name, c.length(arguments)),
              Copy(Rax, target),
              ..pop_registers(c.reverse(saved))
            ]),
          ))
        }
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

fn allocate_arguments(
  arguments: List(Tree),
) -> Result(List(Instruction), String) {
  case arguments {
    [] -> Ok([])
    [value, ..rest] -> {
      // Previous arguments and saved caller values are already on the stack.
      // Each new argument may use the whole register pool, in source order.
      use code <- c.then(allocate(value, pool()))
      use tail <- c.then(allocate_arguments(rest))
      Ok(c.append(code, [Push(Rax), ..tail]))
    }
  }
}

fn push_registers(registers: List(Register)) -> List(Instruction) {
  case registers {
    [] -> []
    [register, ..rest] -> [Push(register), ..push_registers(rest)]
  }
}

fn pop_registers(registers: List(Register)) -> List(Instruction) {
  case registers {
    [] -> []
    [register, ..rest] -> [Pop(register), ..pop_registers(rest)]
  }
}

// All allocatable registers, recovery scratch and condition flags are volatile
// across an unknown named callee. R14/R15/RBP/RSP are outside the value pool.
pub fn clobbers(instruction: Instruction) -> List(Register) {
  case instruction {
    NamedCall(_, _) -> [Rax, Rcx, Rdx, Rdi, Flags]
    _ -> []
  }
}

pub fn uses(instruction: Instruction) -> List(Register) {
  case instruction {
    Constant(_, _) | ReadLocal(_, _) | Pop(_) | NamedCall(_, _) -> []
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
    NamedCall(_, _) -> clobbers(instruction)
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
