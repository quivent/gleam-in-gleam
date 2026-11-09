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
  Equal
  NotEqual
  Less
  LessEqual
  Greater
  GreaterEqual
}

pub type Instruction {
  Constant(target: Register, value: Int)
  ReadLocal(target: Register, name: String)
  ReadParameter(target: Register, offset: Int)
  Copy(source: Register, target: Register)
  Push(Register)
  Pop(Register)
  Calculate(operator: Operator, right: Register, target: Register)
  Negate(Register)
  OverflowGuard
  NamedCall(name: String, argument_count: Int)
  Mark(String)
  Jump(String)
  JumpZero(value: Register, target: String)
}

type Tree {
  Literal(Int)
  Local(String)
  Parameter(Int)
  Unary(Tree)
  Binary(Operator, Tree, Tree)
  DirectCall(String, List(Tree))
  Choose(Tree, Tree, Tree)
}

// Unsupported regions retain the existing lowering, not an inferred clobber set.
pub fn plan(value: t.Typed) -> Result(List(Instruction), String) {
  use tree <- c.then(recognize(value))
  use code <- c.then(allocate(tree, pool(), "root"))
  optimize(code)
}

fn pool() -> List(Register) {
  [Rax, Rcx, Rdx]
}

fn recognize(value: t.Typed) -> Result(Tree, String) {
  case value.type_ {
    a.Integer | a.Boolean ->
      case value.node {
        t.IntegerNode(n) -> Ok(Literal(n))
        t.BooleanNode(value) ->
          Ok(
            Literal(case value {
              True -> 1
              False -> 0
            }),
          )
        t.CaseNode(subject, arms) -> recognize_case(subject, arms)
        t.UnaryNode("!", child) -> {
          use child <- c.then(recognize(child))
          Ok(Choose(child, Literal(0), Literal(1)))
        }
        t.BinaryNode("&&", left, right) -> {
          use left <- c.then(recognize(left))
          use right <- c.then(recognize(right))
          Ok(Choose(left, right, Literal(0)))
        }
        t.BinaryNode("||", left, right) -> {
          use left <- c.then(recognize(left))
          use right <- c.then(recognize(right))
          Ok(Choose(left, Literal(1), right))
        }
        t.VariableNode(name) -> Ok(Local(name))
        t.ParameterNode(offset) -> Ok(Parameter(offset))
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
            "==" -> Ok(Equal)
            "!=" -> Ok(NotEqual)
            "<" -> Ok(Less)
            "<=" -> Ok(LessEqual)
            ">" -> Ok(Greater)
            ">=" -> Ok(GreaterEqual)
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

fn recognize_case(subject: t.Typed, arms: List(t.Arm)) -> Result(Tree, String) {
  case arms {
    [t.Arm(first, a.NoGuard, yes), t.Arm(second, a.NoGuard, no)] -> {
      use condition <- c.then(recognize(subject))
      use yes <- c.then(recognize(yes))
      use no <- c.then(recognize(no))
      case subject.type_, first, second {
        a.Boolean, a.BooleanPattern(True), a.BooleanPattern(False)
        | a.Boolean, a.BooleanPattern(True), a.DiscardPattern
        -> Ok(Choose(condition, yes, no))
        a.Boolean, a.BooleanPattern(False), a.BooleanPattern(True)
        | a.Boolean, a.BooleanPattern(False), a.DiscardPattern
        -> Ok(Choose(condition, no, yes))
        a.Integer, a.IntegerPattern(n), a.DiscardPattern ->
          Ok(Choose(Binary(Equal, condition, Literal(n)), yes, no))
        _, _, _ -> Error("Case pattern boundary requires legacy lowering")
      }
    }
    _ -> Error("Case shape requires legacy lowering")
  }
}

fn calculation(
  op: Operator,
  right: Register,
  target: Register,
) -> List(Instruction) {
  case op {
    Add | Subtract | Multiply -> [Calculate(op, right, target), OverflowGuard]
    _ -> [Calculate(op, right, target)]
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
  path: String,
) -> Result(List(Instruction), String) {
  case available {
    [] -> Error("Outside the supported integer region")
    [target, ..remaining] ->
      case tree {
        Literal(n) -> Ok([Constant(target, n)])
        Local(name) -> Ok([ReadLocal(target, name)])
        Parameter(offset) -> Ok([ReadParameter(target, offset)])
        DirectCall(name, arguments) -> {
          // The occupied prefix contains ancestor values still needed after the
          // call. Save it BEFORE evaluating arguments, which may themselves call.
          let saved = without(pool(), available)
          use arguments_code <- c.then(allocate_arguments(
            arguments,
            path <> "a",
            0,
          ))
          Ok(c.append(
            push_registers(saved),
            c.append(arguments_code, [
              NamedCall(name, c.length(arguments)),
              Copy(Rax, target),
              ..pop_registers(c.reverse(saved))
            ]),
          ))
        }
        Choose(condition, yes, no) -> {
          let saved = without(pool(), available)
          use condition <- c.then(allocate(condition, pool(), path <> "c"))
          use yes <- c.then(allocate(yes, pool(), path <> "t"))
          use no <- c.then(allocate(no, pool(), path <> "f"))
          let other = path <> ":else"
          let finish = path <> ":join"
          Ok(c.append(
            push_registers(saved),
            c.append(condition, [
              JumpZero(Rax, other),
              ..c.append(yes, [
                Jump(finish),
                Mark(other),
                ..c.append(no, [
                  Mark(finish),
                  Copy(Rax, target),
                  ..pop_registers(c.reverse(saved))
                ])
              ])
            ]),
          ))
        }
        Unary(child) -> {
          use code <- c.then(allocate(child, available, path <> "u"))
          Ok(c.append(code, [Negate(target), OverflowGuard]))
        }
        Binary(op, left, right) -> {
          // Preserve left-to-right evaluation and each immediate overflow trap.
          use lhs <- c.then(allocate(left, available, path <> "l"))
          case remaining {
            [rhs, ..] -> {
              use right_code <- c.then(allocate(right, remaining, path <> "r"))
              Ok(c.append(
                lhs,
                c.append(right_code, calculation(op, rhs, target)),
              ))
            }
            [] -> {
              use right_code <- c.then(allocate(right, available, path <> "r"))
              Ok(
                c.append(lhs, [
                  Push(target),
                  ..c.append(
                    right_code,
                    c.append(
                      [Pop(Rdi)],
                      c.append(calculation(op, target, Rdi), [Copy(Rdi, target)]),
                    ),
                  )
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
  path: String,
  index: Int,
) -> Result(List(Instruction), String) {
  case arguments {
    [] -> Ok([])
    [value, ..rest] -> {
      // Previous arguments and saved caller values are already on the stack.
      // Each new argument may use the whole register pool, in source order.
      use code <- c.then(allocate(value, pool(), path <> c.decimal(index)))
      use tail <- c.then(allocate_arguments(rest, path, index + 1))
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
    Constant(_, _)
    | ReadLocal(_, _)
    | ReadParameter(_, _)
    | Pop(_)
    | NamedCall(_, _)
    | Mark(_)
    | Jump(_) -> []
    JumpZero(value, _) -> [value]
    Copy(source, _) | Push(source) | Negate(source) -> [source]
    Calculate(_, right, target) -> [right, target]
    OverflowGuard -> [Flags]
  }
}

pub fn definitions(instruction: Instruction) -> List(Register) {
  case instruction {
    Constant(target, _)
    | ReadLocal(target, _)
    | ReadParameter(target, _)
    | Copy(_, target)
    | Pop(target) -> [target]
    Negate(target) | Calculate(_, _, target) -> [target, Flags]
    Push(_) | OverflowGuard | Mark(_) | Jump(_) -> []
    JumpZero(_, _) -> [Flags]
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

pub type LiveRow {
  LiveRow(index: Int, live_in: List(Register), live_out: List(Register))
}

fn ordered(values: List(Register)) -> List(Register) {
  order_from([Rax, Rcx, Rdx, Rdi, Flags], values)
}

fn order_from(order: List(Register), values: List(Register)) -> List(Register) {
  case order {
    [] -> []
    [value, ..rest] ->
      case member(value, values) {
        True -> [value, ..order_from(rest, values)]
        False -> order_from(rest, values)
      }
  }
}

fn labels(
  code: List(Instruction),
  index: Int,
  found: List(#(String, Int)),
) -> Result(List(#(String, Int)), String) {
  case code {
    [] -> Ok(found)
    [Mark(name), ..rest] ->
      case c.lookup(found, name) {
        Ok(_) -> Error("Duplicate flow label: " <> name)
        Error(_) -> labels(rest, index + 1, [#(name, index), ..found])
      }
    [_, ..rest] -> labels(rest, index + 1, found)
  }
}

fn index_code(
  code: List(Instruction),
  index: Int,
  reversed: List(#(Int, Instruction)),
) -> List(#(Int, Instruction)) {
  case code {
    [] -> reversed
    [instruction, ..rest] ->
      index_code(rest, index + 1, [#(index, instruction), ..reversed])
  }
}

fn read_live(index: Int, rows: List(LiveRow)) -> List(Register) {
  case rows {
    [] -> []
    [row, ..rest] ->
      case row.index == index {
        True -> row.live_in
        False -> read_live(index, rest)
      }
  }
}

fn edge(
  index: Int,
  end: Int,
  updated: List(LiveRow),
  previous: List(LiveRow),
) -> List(Register) {
  case index == end {
    True -> [Rax]
    False -> {
      // Updated rows take precedence, including an explicitly empty live set.
      case find_row(index, updated) {
        Ok(row) -> row.live_in
        Error(_) -> read_live(index, previous)
      }
    }
  }
}

fn find_row(index: Int, rows: List(LiveRow)) -> Result(LiveRow, String) {
  case rows {
    [] -> Error("Missing flow row")
    [row, ..rest] ->
      case row.index == index {
        True -> Ok(row)
        False -> find_row(index, rest)
      }
  }
}

fn sweep(
  nodes: List(#(Int, Instruction)),
  names: List(#(String, Int)),
  end: Int,
  previous: List(LiveRow),
  updated: List(LiveRow),
) -> Result(List(LiveRow), String) {
  case nodes {
    [] -> Ok(updated)
    [#(index, instruction), ..rest] -> {
      let next = edge(index + 1, end, updated, previous)
      use outgoing <- c.then(case instruction {
        Jump(name) -> {
          use target <- c.then(c.lookup(names, name))
          Ok(edge(target, end, updated, previous))
        }
        JumpZero(_, name) -> {
          use target <- c.then(c.lookup(names, name))
          Ok(union(next, edge(target, end, updated, previous)))
        }
        _ -> Ok(next)
      })
      let outgoing = ordered(outgoing)
      let incoming = ordered(live_before(instruction, outgoing))
      sweep(rest, names, end, previous, [
        LiveRow(index, incoming, outgoing),
        ..updated
      ])
    }
  }
}

fn same_rows(left: List(LiveRow), right: List(LiveRow)) -> Bool {
  case left, right {
    [], [] -> True
    [a, ..left], [b, ..right] ->
      a.index == b.index
      && a.live_in == b.live_in
      && a.live_out == b.live_out
      && same_rows(left, right)
    _, _ -> False
  }
}

fn solve(
  nodes: List(#(Int, Instruction)),
  names: List(#(String, Int)),
  end: Int,
  previous: List(LiveRow),
  fuel: Int,
) -> Result(List(LiveRow), String) {
  case fuel == 0 {
    True -> Error("Control-flow liveness did not converge")
    False -> {
      use rows <- c.then(sweep(nodes, names, end, previous, []))
      case same_rows(rows, previous) {
        True -> Ok(rows)
        False -> solve(nodes, names, end, rows, fuel - 1)
      }
    }
  }
}

// Successor-aware fixed point, including backedges. Undefined/duplicate labels
// are errors. The final continuing edge requires the expression result in RAX.
pub fn analyze(code: List(Instruction)) -> Result(List(LiveRow), String) {
  use names <- c.then(labels(code, 0, []))
  let size = c.length(code)
  solve(index_code(code, 0, []), names, size, [], size * 5 + 2)
}

fn removable(instruction: Instruction, live: List(Register)) -> Bool {
  case instruction {
    Constant(target, _) | ReadLocal(target, _) | ReadParameter(target, _) ->
      !member(target, live)
    Copy(source, target) -> source == target || !member(target, live)
    _ -> False
  }
}

fn filter_moves(
  code: List(Instruction),
  rows: List(LiveRow),
  reversed: List(Instruction),
) -> List(Instruction) {
  case code, rows {
    [], [] -> c.reverse(reversed)
    [instruction, ..code], [row, ..rows] ->
      case removable(instruction, row.live_out) {
        True -> filter_moves(code, rows, reversed)
        False -> filter_moves(code, rows, [instruction, ..reversed])
      }
    _, _ -> c.reverse(reversed)
  }
}

fn optimize(code: List(Instruction)) -> Result(List(Instruction), String) {
  case has_flow(code) {
    False -> Ok(retain_linear(c.reverse(code), [Rax], []))
    True -> optimize_flow(code)
  }
}

fn has_flow(code: List(Instruction)) -> Bool {
  case code {
    [] -> False
    [Mark(_), ..] | [Jump(_), ..] | [JumpZero(_, _), ..] -> True
    [_, ..rest] -> has_flow(rest)
  }
}

fn retain_linear(
  reversed: List(Instruction),
  live: List(Register),
  kept: List(Instruction),
) -> List(Instruction) {
  case reversed {
    [] -> kept
    [instruction, ..rest] ->
      case removable(instruction, live) {
        True -> retain_linear(rest, live, kept)
        False ->
          retain_linear(rest, live_before(instruction, live), [
            instruction,
            ..kept
          ])
      }
  }
}

fn optimize_flow(code: List(Instruction)) -> Result(List(Instruction), String) {
  use rows <- c.then(analyze(code))
  let kept = filter_moves(code, rows, [])
  case c.length(kept) == c.length(code) {
    True -> Ok(kept)
    False -> optimize_flow(kept)
  }
}

pub fn eliminate_dead_moves(code: List(Instruction)) -> List(Instruction) {
  case optimize(code) {
    Ok(kept) -> kept
    Error(_) -> code
  }
}
