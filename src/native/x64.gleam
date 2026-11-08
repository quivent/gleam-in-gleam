import native/assembler as asm
import native/ast as a
import native/check as t
import native/cli_limits
import native/cli_runtime
import native/core as c
import native/definitions as d
import native/equality as eq
import native/equality_runtime as eq_runtime
import native/heap
import native/loop_idioms
import native/registers as r
import native/string_runtime

type State {
  State(
    serial: Int,
    slots: Int,
    env: List(#(String, Int)),
    data: List(asm.Part),
    needs_heap: Bool,
    // Reverse helper order; each immutable body is retained once as a span.
    closures: List(asm.Part),
    strings: List(String),
    globals: d.Context,
    equalities: List(#(a.Type, eq.Plan)),
  )
}

type Generated =
  Result(#(List(asm.Part), State), String)

// Tail context is passed explicitly. Closures and ordinary operands use NoTail,
// so an enclosing function's reentry can never leak into a helper's frame.
type TailMode {
  NoTail
  SelfTail(name: String, arity: Int)
}

fn raw(bytes: BitArray) -> asm.Part {
  asm.Bytes(bytes)
}

fn jump(target: String) -> asm.Part {
  asm.Relative(<<233>>, target)
}

fn call(target: String) -> asm.Part {
  asm.Relative(<<232>>, target)
}

fn branch(code: Int, target: String) -> asm.Part {
  asm.Relative(<<15, code>>, target)
}

fn load(offset: Int) -> asm.Part {
  raw(<<72, 139, 133, offset:32-little>>)
}

fn store(offset: Int) -> asm.Part {
  raw(<<72, 137, 133, offset:32-little>>)
}

fn immediate(n: Int) -> asm.Part {
  raw(<<72, 184, n:64-little>>)
}

fn label(state: State) -> #(String, State) {
  #("L" <> c.decimal(state.serial), State(..state, serial: state.serial + 1))
}

fn slot(state: State) -> #(Int, State) {
  let count = state.slots + 1
  #(0 - count * 8, State(..state, slots: count))
}

// Sibling arms cannot execute together. Their local slots may overlap, but
// the function must reserve the largest branch footprint at the join.
fn reserve_slots(count: Int, state: State) -> State {
  case count > state.slots {
    True -> State(..state, slots: count)
    False -> state
  }
}

fn add_string(bytes: BitArray, state: State) -> #(String, State) {
  let #(name, state) = label(state)
  let size = c.byte_length(bytes)
  #(
    name,
    State(..state, data: [
      raw(<<size:64-little, bytes:bits, 10>>),
      asm.Label(name),
      ..state.data
    ]),
  )
}

pub fn generate(functions: List(t.Function)) -> Result(BitArray, String) {
  generate_with(functions, d.Context([], [], [], [], ""))
}

pub fn generate_with(
  functions: List(t.Function),
  globals: d.Context,
) -> Result(BitArray, String) {
  use parts <- c.then(plan_with(functions, globals))
  asm.assemble(parts)
}

pub fn plan_with(
  functions: List(t.Function),
  globals: d.Context,
) -> Result(List(asm.Part), String) {
  plan_program(functions, globals, False, [], [], 67_108_864)
}

// Explicit effect-runner entrypoint; ordinary language programs keep their ABI.
pub fn generate_cli(
  functions: List(t.Function),
  globals: d.Context,
) -> Result(BitArray, String) {
  use parts <- c.then(plan_cli(functions, globals))
  asm.assemble(parts)
}

pub fn plan_cli(
  functions: List(t.Function),
  globals: d.Context,
) -> Result(List(asm.Part), String) {
  use #(entry, runtime) <- c.then(cli_runtime.generate(globals))
  plan_program(
    functions,
    globals,
    True,
    entry,
    runtime,
    cli_limits.arena_capacity(),
  )
}

// Explicit diagnostic build path, separate from the production CLI entry.
pub fn plan_cli_with_limit(
  functions: List(t.Function),
  globals: d.Context,
  source_limit: Int,
  arena_capacity: Int,
) -> Result(List(asm.Part), String) {
  use #(entry, runtime) <- c.then(cli_runtime.generate_with_limit(
    globals,
    source_limit,
  ))
  plan_program(functions, globals, True, entry, runtime, arena_capacity)
}

fn plan_program(
  functions: List(t.Function),
  globals: d.Context,
  cli: Bool,
  cli_entry: List(asm.Part),
  cli_code: List(asm.Part),
  arena_capacity: Int,
) -> Result(List(asm.Part), String) {
  use #(bodies, state) <- c.then(function_list(
    functions,
    State(0, 0, [], [], cli, [], [], globals, []),
  ))
  use equality_code <- c.then(equality_helpers(state.equalities, 0))
  let init = case state.needs_heap {
    True -> [call("rt:heap_init")]
    False -> []
  }
  use heap_runtime <- c.then(case state.needs_heap {
    True -> heap.runtime_with_capacity(arena_capacity)
    False -> Ok([])
  })
  let entry = case cli {
    True -> cli_entry
    False ->
      asm.join(init, [
        call("fn:main"),
        raw(<<49, 255, 184, 60, 0, 0, 0, 15, 5>>),
      ])
  }
  let parts =
    asm.join(
      entry,
      asm.join(
        asm.join(asm.join(bodies, c.reverse(state.closures)), equality_code),
        asm.join(
          asm.join(cli_code, runtime()),
          asm.join(
            heap_runtime,
            asm.join(
              string_runtime.generate(state.strings),
              c.reverse(state.data),
            ),
          ),
        ),
      ),
    )
  Ok(parts)
}

fn function_list(functions: List(t.Function), state: State) -> Generated {
  case functions {
    [] -> Ok(#([], state))
    [f, ..rest] -> {
      let env = parameter_offsets(f.parameters, c.length(f.parameters), 0)
      use #(body, state) <- c.then(function_body(
        f,
        State(..state, slots: 0, env: env),
      ))
      // The stack frame is known after allocating all locals, including branches.
      let frame = { { state.slots * 8 + 15 } / 16 } * 16
      let prologue = raw(<<85, 72, 137, 229, 72, 129, 236, frame:32-little>>)
      use #(tail, state) <- c.then(function_list(rest, state))
      Ok(#(
        [
          asm.Label("fn:" <> f.name),
          prologue,
          asm.Label("fn:loop:" <> f.name),
          ..asm.join(body, [
            raw(<<201, 195>>),
            asm.Label("fn:end:" <> f.name),
            ..tail
          ])
        ],
        state,
      ))
    }
  }
}

fn function_body(function: t.Function, state: State) -> Generated {
  case loop_idioms.recognize(function) {
    Ok(loop_idioms.ByteCount(source, counter)) -> {
      use source <- c.then(c.lookup(state.env, source))
      use counter <- c.then(c.lookup(state.env, counter))
      // All owned byte-array descriptors contain their byte length at +16.
      // A pure +1-per-byte loop is length + initial counter, with identical
      // signed-overflow behavior and no temporary suffix descriptors.
      Ok(#(
        [
          load(source),
          raw(<<72, 139, 64, 16>>),
          raw(<<72, 139, 141, counter:32-little, 72, 1, 200>>),
          branch(128, "rt:overflow"),
        ],
        state,
      ))
    }
    Error(_) ->
      statement_mode(
        function.body,
        SelfTail(function.name, c.length(function.parameters)),
        state,
      )
  }
}

fn parameter_offsets(
  params: List(#(String, a.Type)),
  size: Int,
  index: Int,
) -> List(#(String, Int)) {
  case params {
    [] -> []
    [#(name, _), ..rest] -> [
      #(name, 16 + { size - index - 1 } * 8),
      ..parameter_offsets(rest, size, index + 1)
    ]
  }
}

fn statements(xs: List(t.Statement), state: State) -> Generated {
  statement_mode(xs, NoTail, state)
}

fn statement_mode(
  xs: List(t.Statement),
  mode: TailMode,
  state: State,
) -> Generated {
  case xs {
    [] -> Ok(#([immediate(0)], state))
    [t.Evaluate(e)] -> tail_expression(e, mode, state)
    [t.Evaluate(e), ..rest] -> {
      use #(code, state) <- c.then(expression(e, state))
      use #(tail, state) <- c.then(statement_mode(rest, mode, state))
      Ok(#(asm.join(code, tail), state))
    }
    [t.Bind(pat, e), ..rest] -> {
      use #(code, state) <- c.then(expression(e, state))
      let #(offset, state) = slot(state)
      use #(bindings, state) <- c.then(pattern_code(
        pat,
        offset,
        "rt:match",
        state,
      ))
      use #(tail, state) <- c.then(statement_mode(rest, mode, state))
      Ok(#(asm.join(code, [store(offset), ..asm.join(bindings, tail)]), state))
    }
  }
}

fn expression(e: t.Typed, state: State) -> Generated {
  case e.node {
    t.BinaryNode(_, _, _)
    | t.UnaryNode(_, _)
    | t.CallNode(_, _)
    | t.CaseNode(_, _) ->
      case r.plan(e) {
        Ok(code) -> {
          let #(region, state) = label(state)
          use code <- c.then(register_code(
            code,
            state.env,
            "reg:" <> region <> ":",
          ))
          Ok(#(code, state))
        }
        Error(_) -> ordinary_expression(e, state)
      }
    _ -> ordinary_expression(e, state)
  }
}

fn register_number(register: r.Register) -> Result(Int, String) {
  case register {
    r.Rax -> Ok(0)
    r.Rcx -> Ok(1)
    r.Rdx -> Ok(2)
    r.Rdi -> Ok(7)
    r.Flags -> Error("Flags cannot be a machine operand")
  }
}

fn register_code(
  code: List(r.Instruction),
  env: List(#(String, Int)),
  prefix: String,
) -> Result(List(asm.Part), String) {
  case code {
    [] -> Ok([])
    [instruction, ..rest] -> {
      use head <- c.then(register_instruction(instruction, env, prefix))
      use tail <- c.then(register_code(rest, env, prefix))
      Ok(asm.join(head, tail))
    }
  }
}

fn register_instruction(
  instruction: r.Instruction,
  env: List(#(String, Int)),
  prefix: String,
) -> Result(List(asm.Part), String) {
  case instruction {
    r.Constant(target, n) -> {
      use target <- c.then(register_number(target))
      Ok([raw(<<72, { 184 + target }, n:64-little>>)])
    }
    r.ReadLocal(target, name) -> {
      use target <- c.then(register_number(target))
      use offset <- c.then(c.lookup(env, name))
      Ok([raw(<<72, 139, { 133 + target * 8 }, offset:32-little>>)])
    }
    r.Copy(source, target) -> {
      use source <- c.then(register_number(source))
      use target <- c.then(register_number(target))
      Ok([raw(<<72, 137, { 192 + source * 8 + target }>>)])
    }
    r.Push(register) -> {
      use register <- c.then(register_number(register))
      Ok([raw(<<{ 80 + register }>>)])
    }
    r.Pop(register) -> {
      use register <- c.then(register_number(register))
      Ok([raw(<<{ 88 + register }>>)])
    }
    r.Calculate(operator, right, target) -> {
      use right <- c.then(register_number(right))
      use target <- c.then(register_number(target))
      let bytes = case operator {
        r.Add -> <<72, 1, { 192 + right * 8 + target }>>
        r.Subtract -> <<72, 41, { 192 + right * 8 + target }>>
        r.Multiply -> <<72, 15, 175, { 192 + target * 8 + right }>>
        _ -> <<72, 57, { 192 + right * 8 + target }>>
      }
      let suffix = case operator {
        r.Add | r.Subtract | r.Multiply -> <<>>
        _ -> {
          let condition = case operator {
            r.Equal -> 148
            r.NotEqual -> 149
            r.Less -> 156
            r.LessEqual -> 158
            r.Greater -> 159
            r.GreaterEqual -> 157
            _ -> 148
          }
          <<
            64,
            15,
            condition,
            { 192 + target },
            72,
            15,
            182,
            { 192 + target * 9 },
          >>
        }
      }
      Ok([raw(<<bytes:bits, suffix:bits>>)])
    }
    r.Negate(register) -> {
      use register <- c.then(register_number(register))
      Ok([raw(<<72, 247, { 216 + register }>>)])
    }
    r.OverflowGuard -> Ok([branch(128, "rt:overflow")])
    r.Mark(name) -> Ok([asm.Label(prefix <> name)])
    r.Jump(name) -> Ok([jump(prefix <> name)])
    r.JumpZero(value, name) -> {
      use value <- c.then(register_number(value))
      Ok([raw(<<72, 133, { 192 + value * 9 }>>), branch(132, prefix <> name)])
    }
    r.NamedCall(name, argument_count) -> {
      let cleanup = argument_count * 8
      Ok([call("fn:" <> name), raw(<<72, 129, 196, cleanup:32-little>>)])
    }
  }
}

fn ordinary_expression(e: t.Typed, state: State) -> Generated {
  case e.node {
    t.IntegerNode(n) -> Ok(#([immediate(n)], state))
    t.BooleanNode(b) ->
      Ok(#(
        [
          immediate(case b {
            True -> 1
            False -> 0
          }),
        ],
        state,
      ))
    t.UnitNode -> Ok(#([immediate(0)], state))
    t.StringNode(s) -> {
      let #(name, state) = add_string(s, state)
      Ok(#([asm.Relative(<<72, 141, 5>>, name)], state))
    }
    t.BitArrayNode(segments) -> bit_array(segments, state)
    t.TupleNode(elements) -> object(elements, 1, state)
    t.ConstructorNode(tag, fields) -> object(fields, tag, state)
    t.FieldNode(target, index, tags) -> {
      use #(code, state) <- c.then(expression(target, state))
      let #(found, state) = label(state)
      let offset = 16 + index * 8
      let inspect = [
        raw(<<72, 133, 192>>),
        branch(132, "rt:match"),
        ..asm.join(field_tags(tags, found), [
          asm.Label(found),
          raw(<<72, 139, 128, offset:32-little>>),
        ])
      ]
      Ok(#(asm.join(code, inspect), state))
    }
    t.TupleIndexNode(tuple, index) -> {
      use #(code, state) <- c.then(expression(tuple, state))
      let offset = 16 + index * 8
      Ok(#(asm.join(code, [raw(<<72, 139, 128, offset:32-little>>)]), state))
    }
    t.ListNode(elements, tail) -> {
      use #(code, state) <- c.then(arguments(elements, state))
      use #(tail_code, state) <- c.then(case tail {
        t.EmptyTail -> Ok(#([immediate(0)], state))
        t.ListTail(tail) -> expression(tail, state)
      })
      let n = c.length(elements)
      Ok(#(
        asm.join(code, asm.join(tail_code, cons_cells(n))),
        State(..state, needs_heap: state.needs_heap || n > 0),
      ))
    }
    t.VariableNode(name) -> {
      use offset <- c.then(c.lookup(state.env, name))
      Ok(#([load(offset)], state))
    }
    t.UnaryNode(op, value) -> {
      use #(code, state) <- c.then(expression(value, state))
      let instructions = case op {
        "-" -> [raw(<<72, 247, 216>>), branch(128, "rt:overflow")]
        _ -> [raw(<<72, 131, 240, 1>>)]
      }
      Ok(#(asm.join(code, instructions), state))
    }
    t.BinaryNode(op, left, right) -> binary(op, left, right, state)
    t.EqualityNode(left, right, type_, invert) -> {
      use #(code, state) <- c.then(expression(left, state))
      use #(rhs, state) <- c.then(expression(right, state))
      use #(target, state) <- c.then(equality_target(type_, state))
      let invert = case invert {
        True -> [raw(<<72, 131, 240, 1>>)]
        False -> []
      }
      Ok(#(
        asm.join(code, [
          raw(<<80>>),
          ..asm.join(rhs, [raw(<<89>>), call(target), ..invert])
        ]),
        state,
      ))
    }
    t.CallNode(name, args) -> {
      use #(code, state) <- c.then(arguments(args, state))
      let cleanup = c.length(args) * 8
      Ok(#(
        asm.join(code, [
          call("fn:" <> name),
          raw(<<72, 129, 196, cleanup:32-little>>),
        ]),
        state,
      ))
    }
    t.FunctionNode(name) -> descriptor("fn:" <> name, [], state)
    t.ClosureNode(params, body, captures) ->
      closure(params, body, captures, state)
    t.IndirectCallNode(target, args) -> {
      use #(target_code, state) <- c.then(expression(target, state))
      use #(argument_code, state) <- c.then(arguments(args, state))
      let offset = c.length(args) * 8
      let cleanup = offset + 8
      let invoke = [
        raw(<<72, 139, 132, 36, offset:32-little, 72, 133, 192>>),
        branch(132, "rt:match"),
        raw(<<72, 131, 120, 8, 0>>),
        branch(133, "rt:match"),
        raw(<<72, 139, 64, 16, 72, 133, 192>>),
        branch(132, "rt:match"),
        raw(<<255, 208, 72, 129, 196, cleanup:32-little>>),
      ]
      Ok(#(
        asm.join(target_code, [raw(<<80>>), ..asm.join(argument_code, invoke)]),
        state,
      ))
    }
    t.BlockNode(body) -> {
      let env = state.env
      use #(code, state) <- c.then(statements(body, state))
      Ok(#(code, State(..state, env: env)))
    }
    t.MultiCaseNode(subjects, arms) -> multi_case(subjects, arms, NoTail, state)
    t.CaseNode(subject, arms) -> case_code(subject, arms, NoTail, state)
    t.EchoNode(inner) -> {
      use #(code, state) <- c.then(expression(inner, state))
      let #(print, state) = render_echo(inner.type_, state)
      Ok(#(asm.join(code, print), state))
    }
  }
}

fn tail_expression(e: t.Typed, mode: TailMode, state: State) -> Generated {
  case mode {
    NoTail -> expression(e, state)
    SelfTail(self, arity) ->
      case e.node {
        t.CallNode(name, args) if name == self -> {
          use _ <- c.then(case c.length(args) == arity {
            True -> Ok(Nil)
            False -> Error("Internal self-tail-call arity mismatch")
          })
          // Evaluate every argument left to right before modifying ANY parameter.
          // Popping in reverse order matches the existing stack argument ABI.
          use #(code, state) <- c.then(arguments(args, state))
          Ok(#(
            asm.join(
              code,
              asm.join(tail_parameters(arity, 0), [jump("fn:loop:" <> self)]),
            ),
            state,
          ))
        }
        t.BlockNode(body) -> {
          let env = state.env
          use #(code, state) <- c.then(statement_mode(body, mode, state))
          Ok(#(code, State(..state, env: env)))
        }
        t.CaseNode(subject, arms) -> case_code(subject, arms, mode, state)
        t.MultiCaseNode(subjects, arms) ->
          multi_case(subjects, arms, mode, state)
        _ -> expression(e, state)
      }
  }
}

fn tail_parameters(remaining: Int, index: Int) -> List(asm.Part) {
  case remaining {
    0 -> []
    _ -> [
      raw(<<88>>),
      store(16 + index * 8),
      ..tail_parameters(remaining - 1, index + 1)
    ]
  }
}

fn case_code(
  subject: t.Typed,
  arms: List(t.Arm),
  mode: TailMode,
  state: State,
) -> Generated {
  case comparison_case(subject, arms) {
    Ok(#(left, right, false_condition, first, second)) ->
      comparison_case_code(
        left,
        right,
        false_condition,
        first,
        second,
        mode,
        state,
      )
    Error(_) -> ordinary_case(subject, arms, mode, state)
  }
}

// Preserve a comparison as flags until its case consumer. No unselected arm is
// evaluated, and guard/binding patterns retain ordinary pattern lowering.
fn comparison_case(
  subject: t.Typed,
  arms: List(t.Arm),
) -> Result(#(t.Typed, t.Typed, Int, t.Typed, t.Typed), String) {
  case subject.node, arms {
    t.BinaryNode(op, left, right),
      [
        t.Arm(a.BooleanPattern(value), a.NoGuard, first),
        t.Arm(other, a.NoGuard, second),
      ]
    -> {
      use _ <- c.then(case other {
        a.DiscardPattern -> Ok(Nil)
        a.BooleanPattern(alternate) if alternate != value -> Ok(Nil)
        _ -> Error("Not complementary Boolean arms")
      })
      use _ <- c.then(case left.type_, right.type_ {
        a.Integer, a.Integer -> Ok(Nil)
        _, _ -> Error("Not integer comparison operands")
      })
      use condition <- c.then(case op {
        "==" -> Ok(133)
        "!=" -> Ok(132)
        "<" -> Ok(141)
        "<=" -> Ok(143)
        ">" -> Ok(142)
        ">=" -> Ok(140)
        _ -> Error("Not a primitive comparison")
      })
      let condition = case value {
        True -> condition
        False ->
          case condition % 2 {
            0 -> condition + 1
            _ -> condition - 1
          }
      }
      Ok(#(left, right, condition, first, second))
    }
    _, _ -> Error("Not a direct comparison case")
  }
}

fn comparison_case_code(
  left: t.Typed,
  right: t.Typed,
  condition: Int,
  first: t.Typed,
  second: t.Typed,
  mode: TailMode,
  state: State,
) -> Generated {
  use #(left_code, state) <- c.then(expression(left, state))
  use #(condition_code, state) <- c.then(binary_values(
    left,
    right,
    left_code,
    state,
  ))
  let #(alternate, state) = label(state)
  let #(finish, state) = label(state)
  let base_slots = state.slots
  let env = state.env
  use #(yes, state) <- c.then(tail_expression(first, mode, state))
  let yes_slots = state.slots
  let state = State(..state, env: env, slots: base_slots)
  use #(no, state) <- c.then(tail_expression(second, mode, state))
  Ok(#(
    asm.join(condition_code, [
      raw(<<72, 57, 193>>),
      branch(condition, alternate),
      ..asm.join(yes, [
        jump(finish),
        asm.Label(alternate),
        ..asm.join(no, [asm.Label(finish)])
      ])
    ]),
    reserve_slots(yes_slots, State(..state, env: env)),
  ))
}

fn ordinary_case(
  subject: t.Typed,
  arms: List(t.Arm),
  mode: TailMode,
  state: State,
) -> Generated {
  use #(code, state) <- c.then(expression(subject, state))
  let #(offset, state) = slot(state)
  let #(finish, state) = label(state)
  use #(matches, state) <- c.then(case_arms(arms, offset, finish, mode, state))
  Ok(#(
    asm.join(code, [store(offset), ..asm.join(matches, [asm.Label(finish)])]),
    state,
  ))
}

fn descriptor(
  entry: String,
  captures: List(String),
  state: State,
) -> Generated {
  use values <- c.then(capture_values(captures, state.env))
  let n = c.length(captures)
  let size = 24 + n * 8
  let create = [
    raw(<<191, size:32-little>>),
    call("rt:allocate"),
    raw(<<72, 199, 0, size:32-little, 72, 199, 64, 8, 0, 0, 0, 0>>),
    asm.Relative(<<72, 141, 13>>, entry),
    raw(<<72, 137, 72, 16>>),
  ]
  Ok(#(
    asm.join(values, asm.join(create, capture_stores(n - 1))),
    State(..state, needs_heap: True),
  ))
}

fn capture_values(
  captures: List(String),
  env: List(#(String, Int)),
) -> Result(List(asm.Part), String) {
  case captures {
    [] -> Ok([])
    [name, ..rest] -> {
      use offset <- c.then(c.lookup(env, name))
      use tail <- c.then(capture_values(rest, env))
      Ok([load(offset), raw(<<80>>), ..tail])
    }
  }
}

fn capture_stores(index: Int) -> List(asm.Part) {
  case index < 0 {
    True -> []
    False -> {
      let offset = 24 + index * 8
      [raw(<<89, 72, 137, 136, offset:32-little>>), ..capture_stores(index - 1)]
    }
  }
}

fn closure(
  params: List(#(String, a.Type)),
  body: List(t.Statement),
  captures: List(String),
  state: State,
) -> Generated {
  let outer_env = state.env
  let outer_slots = state.slots
  let #(entry, state) = label(state)
  let parameter_env = parameter_offsets(params, c.length(params), 0)
  let helper_state = State(..state, env: parameter_env, slots: 0)
  let hidden = 16 + c.length(params) * 8
  let #(initialise, helper_state) =
    capture_locals(captures, hidden, 0, helper_state)
  use #(code, helper_state) <- c.then(statements(body, helper_state))
  let frame = { { helper_state.slots * 8 + 15 } / 16 } * 16
  let prologue = raw(<<85, 72, 137, 229, 72, 129, 236, frame:32-little>>)
  let helper = [
    asm.Label(entry),
    prologue,
    ..asm.join(initialise, asm.join(code, [raw(<<201, 195>>)]))
  ]
  let state =
    State(..helper_state, env: outer_env, slots: outer_slots, closures: [
      asm.Span(helper),
      ..helper_state.closures
    ])
  descriptor(entry, captures, state)
}

fn capture_locals(
  captures: List(String),
  hidden: Int,
  index: Int,
  state: State,
) -> #(List(asm.Part), State) {
  case captures {
    [] -> #([], state)
    [name, ..rest] -> {
      let #(offset, state) = slot(state)
      let state = State(..state, env: [#(name, offset), ..state.env])
      let field = 24 + index * 8
      let instructions = [
        load(hidden),
        raw(<<72, 139, 128, field:32-little>>),
        store(offset),
      ]
      let #(tail, state) = capture_locals(rest, hidden, index + 1, state)
      #(asm.join(instructions, tail), state)
    }
  }
}

fn arguments(args: List(t.Typed), state: State) -> Generated {
  case args {
    [] -> Ok(#([], state))
    [arg, ..rest] -> {
      use #(code, state) <- c.then(expression(arg, state))
      use #(tail, state) <- c.then(arguments(rest, state))
      Ok(#(asm.join(code, [raw(<<80>>), ..tail]), state))
    }
  }
}

fn binary(
  op: String,
  left: t.Typed,
  right: t.Typed,
  state: State,
) -> Generated {
  use #(left_code, state) <- c.then(expression(left, state))
  case op {
    "&&" | "||" -> {
      let #(finish, state) = label(state)
      use #(right_code, state) <- c.then(expression(right, state))
      let condition = case op {
        "&&" -> 132
        _ -> 133
      }
      Ok(#(
        asm.join(left_code, [
          raw(<<72, 133, 192>>),
          branch(condition, finish),
          ..asm.join(right_code, [asm.Label(finish)])
        ]),
        state,
      ))
    }
    _ -> {
      use #(values, state) <- c.then(binary_values(
        left,
        right,
        left_code,
        state,
      ))
      let #(operation, state) = case left.type_ {
        a.StringType -> {
          let name = case op {
            "<>" -> "concat"
            _ -> "equal"
          }
          let state = string_helper(state, name)
          let invert = case op {
            "!=" -> [raw(<<72, 131, 240, 1>>)]
            _ -> []
          }
          #([call("rt:string_" <> name), ..invert], state)
        }
        _ -> operation(op, state)
      }
      Ok(#(asm.join(values, operation), state))
    }
  }
}

// Bounded look-ahead, not a general register allocator. A leaf RHS has no calls,
// effects or scratch-register clobbers: keep the left word in RCX, right in RAX.
// Anything else still spills the left word before evaluating the right operand.
fn register_leaf(e: t.Typed) -> Bool {
  case e.node {
    t.IntegerNode(_) | t.BooleanNode(_) | t.UnitNode | t.VariableNode(_) -> True
    _ -> False
  }
}

fn leaf_in_rcx(e: t.Typed, state: State) -> Result(List(asm.Part), String) {
  case e.node {
    t.IntegerNode(n) -> Ok([raw(<<72, 185, n:64-little>>)])
    t.BooleanNode(b) -> {
      let n = case b {
        True -> 1
        False -> 0
      }
      Ok([raw(<<72, 185, n:64-little>>)])
    }
    t.UnitNode -> Ok([raw(<<72, 185, 0:64-little>>)])
    t.VariableNode(name) -> {
      use offset <- c.then(c.lookup(state.env, name))
      Ok([raw(<<72, 139, 141, offset:32-little>>)])
    }
    _ -> Error("Internal non-leaf in RCX materialization")
  }
}

fn binary_values(
  left: t.Typed,
  right: t.Typed,
  left_code: List(asm.Part),
  state: State,
) -> Generated {
  case register_leaf(right) {
    True -> {
      use saved <- c.then(case register_leaf(left) {
        True -> leaf_in_rcx(left, state)
        False -> Ok(asm.join(left_code, [raw(<<72, 137, 193>>)]))
      })
      use #(rhs, state) <- c.then(expression(right, state))
      Ok(#(asm.join(saved, rhs), state))
    }
    False -> {
      use #(rhs, state) <- c.then(expression(right, state))
      Ok(#(
        asm.join(left_code, [raw(<<80>>), ..asm.join(rhs, [raw(<<89>>)])]),
        state,
      ))
    }
  }
}

fn operation(op: String, state: State) -> #(List(asm.Part), State) {
  case op {
    "+" -> #([raw(<<72, 1, 200>>), branch(128, "rt:overflow")], state)
    "-" -> #(
      [raw(<<72, 41, 193>>), branch(128, "rt:overflow"), raw(<<72, 137, 200>>)],
      state,
    )
    "*" -> #([raw(<<72, 15, 175, 193>>), branch(128, "rt:overflow")], state)
    "/" | "%" -> {
      let #(zero, state) = label(state)
      let #(normal, state) = label(state)
      let #(finish, state) = label(state)
      #(
        [
          // RDI=right; RAX=left. Gleam defines division/remainder by zero as zero.
          raw(<<72, 137, 199, 72, 137, 200, 72, 133, 255>>),
          branch(132, zero),
          raw(<<72, 131, 255, 255>>),
          branch(133, normal),
          raw(<<72, 186, 0, 0, 0, 0, 0, 0, 0, 128, 72, 57, 208>>),
          branch(132, "rt:overflow"),
          asm.Label(normal),
          raw(<<72, 153, 72, 247, 255>>),
          ..asm.join(
            case op {
              "%" -> [raw(<<72, 137, 208>>)]
              _ -> []
            },
            [jump(finish), asm.Label(zero), raw(<<49, 192>>), asm.Label(finish)],
          )
        ],
        state,
      )
    }
    _ -> {
      let set = case op {
        "==" -> 148
        "!=" -> 149
        "<" -> 156
        "<=" -> 158
        ">" -> 159
        _ -> 157
      }
      #([raw(<<72, 57, 193, 15, set, 192, 72, 15, 182, 192>>)], state)
    }
  }
}

fn case_arms(
  arms: List(t.Arm),
  subject: Int,
  finish: String,
  mode: TailMode,
  state: State,
) -> Generated {
  case arms {
    [] -> Ok(#([jump("rt:match")], state))
    [arm, ..rest] -> {
      let env = state.env
      let base_slots = state.slots
      let #(next, state) = label(state)
      use #(condition_code, state) <- c.then(pattern_code(
        arm.pattern,
        subject,
        next,
        state,
      ))
      use #(guard, state) <- c.then(case arm.guard {
        a.NoGuard -> Ok(#([], state))
        a.Guard(value) -> {
          use #(code, state) <- c.then(expression(value, state))
          Ok(#(
            asm.join(code, [raw(<<72, 133, 192>>), branch(132, next)]),
            state,
          ))
        }
      })
      use #(body, state) <- c.then(tail_expression(arm.body, mode, state))
      let arm_slots = state.slots
      let state = State(..state, env: env, slots: base_slots)
      use #(tail, state) <- c.then(case_arms(rest, subject, finish, mode, state))
      Ok(#(
        asm.join(
          asm.join(condition_code, guard),
          asm.join(body, [jump(finish), asm.Label(next), ..tail]),
        ),
        reserve_slots(arm_slots, state),
      ))
    }
  }
}

fn render_echo(type_: a.Type, state: State) -> #(List(asm.Part), State) {
  case type_ {
    // The type checker rejects compound echo until structural formatting lands.
    a.BitArrayType
    | a.TupleType(_)
    | a.ListType(_)
    | a.QualifiedType(_, _, _)
    | a.NamedType(_)
    | a.AppliedType(_, _)
    | a.VariableType(_)
    | a.FunctionType(_, _)
    | a.Unresolved -> #([jump("rt:match")], state)
    a.Integer -> #([call("rt:print_int")], state)
    a.StringType -> #([call("rt:print_string")], state)
    a.Unit -> {
      let #(name, state) = add_string(<<78, 105, 108>>, state)
      #(
        [
          raw(<<80>>),
          asm.Relative(<<72, 141, 5>>, name),
          call("rt:print_string"),
          raw(<<88>>),
        ],
        state,
      )
    }
    a.Boolean -> {
      let #(yes, state) = add_string(<<84, 114, 117, 101>>, state)
      let #(no, state) = add_string(<<70, 97, 108, 115, 101>>, state)
      let #(otherwise, state) = label(state)
      let #(finish, state) = label(state)
      #(
        [
          raw(<<80, 72, 133, 192>>),
          branch(132, otherwise),
          asm.Relative(<<72, 141, 5>>, yes),
          jump(finish),
          asm.Label(otherwise),
          asm.Relative(<<72, 141, 5>>, no),
          asm.Label(finish),
          call("rt:print_string"),
          raw(<<88>>),
        ],
        state,
      )
    }
  }
}

fn tuple_fields(index: Int) -> List(asm.Part) {
  case index < 0 {
    True -> []
    False -> {
      let offset = 16 + index * 8
      [raw(<<89, 72, 137, 136, offset:32-little>>), ..tuple_fields(index - 1)]
    }
  }
}

fn object(elements: List(t.Typed), tag: Int, state: State) -> Generated {
  use #(code, state) <- c.then(arguments(elements, state))
  let n = c.length(elements)
  let size = 16 + n * 8
  let allocation = [
    raw(<<191, size:32-little>>),
    call("rt:allocate"),
    raw(<<72, 199, 0, size:32-little, 72, 199, 64, 8, tag:32-little>>),
  ]
  Ok(#(
    asm.join(code, asm.join(allocation, tuple_fields(n - 1))),
    State(..state, needs_heap: True),
  ))
}

fn cons_cells(remaining: Int) -> List(asm.Part) {
  case remaining {
    0 -> []
    _ -> [
      // Heads were evaluated left-to-right; build the linked spine right-to-left.
      raw(<<80, 191, 32, 0, 0, 0>>),
      call("rt:allocate"),
      raw(<<
        90,
        89,
        72,
        199,
        0,
        32,
        0,
        0,
        0,
        72,
        199,
        64,
        8,
        2,
        0,
        0,
        0,
        72,
        137,
        72,
        16,
        72,
        137,
        80,
        24,
      >>),
      ..cons_cells(remaining - 1)
    ]
  }
}

fn pattern_code(
  pat: a.Pattern,
  subject: Int,
  failure: String,
  state: State,
) -> Generated {
  case pat {
    a.AliasPattern(inner, name) ->
      pattern_code(
        inner,
        subject,
        failure,
        State(..state, env: [#(name, subject), ..state.env]),
      )
    a.StringPattern(text) -> {
      let #(name, state) = add_string(text, state)
      Ok(#(
        [
          load(subject),
          asm.Relative(<<72, 141, 13>>, name),
          call("rt:string_equal"),
          raw(<<72, 133, 192>>),
          branch(132, failure),
        ],
        string_helper(state, "equal"),
      ))
    }
    a.StringPrefixPattern(prefix, binding, tail) ->
      string_prefix(prefix, binding, tail, subject, failure, state)
    a.BitArrayPattern(_) ->
      Error("Unresolved bit-array pattern in native code generation")
    a.CheckedBitArrayPattern(segments) ->
      bit_pattern(segments, subject, failure, state)
    a.ModuleConstructorPattern(_, _, _, _) ->
      Error("Unresolved module constructor in native lowering")
    a.ConstructorPattern(_, _, _) ->
      Error("Unresolved constructor in native code generation")
    a.CheckedConstructorPattern(tag, fields) -> {
      // Null/tag tests precede every constructor field load.
      let inspect = [
        load(subject),
        raw(<<72, 133, 192>>),
        branch(132, failure),
        raw(<<72, 129, 120, 8, tag:32-little>>),
        branch(133, failure),
      ]
      let patterns = c.map(fields, fn(field) { field.0 })
      use #(body, state) <- c.then(tuple_pattern(
        patterns,
        0,
        subject,
        failure,
        state,
      ))
      Ok(#(asm.join(inspect, body), state))
    }
    a.DiscardPattern -> Ok(#([], state))
    a.VariablePattern(name) ->
      Ok(#([], State(..state, env: [#(name, subject), ..state.env])))
    a.IntegerPattern(n) -> {
      // CMP r64, imm32 sign-extends the immediate. Wider literals must use a
      // full-width scratch register or distinct values can alias after truncation.
      let compare = case n < -2_147_483_648 || n > 2_147_483_647 {
        True -> raw(<<72, 186, n:64-little, 72, 57, 208>>)
        False -> raw(<<72, 61, n:32-little>>)
      }
      Ok(#([load(subject), compare, branch(133, failure)], state))
    }
    a.BooleanPattern(b) -> {
      let n = case b {
        True -> 1
        False -> 0
      }
      Ok(#(
        [load(subject), raw(<<72, 61, n:32-little>>), branch(133, failure)],
        state,
      ))
    }
    a.TuplePattern(patterns) ->
      tuple_pattern(patterns, 0, subject, failure, state)
    a.ListPattern(patterns, tail) ->
      list_pattern(patterns, tail, subject, failure, state)
  }
}

fn field_tags(tags: List(Int), found: String) -> List(asm.Part) {
  case tags {
    [] -> [jump("rt:match")]
    [tag, ..rest] -> [
      raw(<<72, 129, 120, 8, tag:32-little>>),
      branch(132, found),
      ..field_tags(rest, found)
    ]
  }
}

fn tuple_pattern(
  patterns: List(a.Pattern),
  index: Int,
  subject: Int,
  failure: String,
  state: State,
) -> Generated {
  case patterns {
    [] -> Ok(#([], state))
    [pat, ..rest] -> {
      let #(field, state) = slot(state)
      let displacement = 16 + index * 8
      use #(inner, state) <- c.then(pattern_code(pat, field, failure, state))
      use #(tail, state) <- c.then(tuple_pattern(
        rest,
        index + 1,
        subject,
        failure,
        state,
      ))
      Ok(#(
        [
          load(subject),
          raw(<<72, 139, 128, displacement:32-little>>),
          store(field),
          ..asm.join(inner, tail)
        ],
        state,
      ))
    }
  }
}

fn list_pattern(
  patterns: List(a.Pattern),
  tail: a.PatternRest,
  subject: Int,
  failure: String,
  state: State,
) -> Generated {
  case patterns {
    [] ->
      case tail {
        a.NoPatternRest ->
          Ok(#(
            [load(subject), raw(<<72, 133, 192>>), branch(133, failure)],
            state,
          ))
        a.RestPattern(pat) -> pattern_code(pat, subject, failure, state)
      }
    [head, ..rest] -> {
      let #(head_slot, state) = slot(state)
      let #(tail_slot, state) = slot(state)
      let extract = [
        load(subject),
        raw(<<72, 133, 192>>),
        branch(132, failure),
        raw(<<72, 139, 72, 16, 72, 139, 64, 24>>),
        store(tail_slot),
        raw(<<72, 137, 200>>),
        store(head_slot),
      ]
      use #(head_code, state) <- c.then(pattern_code(
        head,
        head_slot,
        failure,
        state,
      ))
      use #(tail_code, state) <- c.then(list_pattern(
        rest,
        tail,
        tail_slot,
        failure,
        state,
      ))
      Ok(#(asm.join(extract, asm.join(head_code, tail_code)), state))
    }
  }
}

fn runtime() -> List(asm.Part) {
  [
    asm.Label("rt:overflow"),
    asm.Label("rt:match"),
    raw(<<191, 70, 0, 0, 0, 184, 60, 0, 0, 0, 15, 5>>),
    asm.Label("rt:print_string"),
    // Static strings are [u64 byte_length][UTF-8 bytes][newline].
    raw(<<
      80,
      72,
      139,
      16,
      72,
      255,
      194,
      72,
      141,
      112,
      8,
      191,
      1,
      0,
      0,
      0,
      184,
      1,
      0,
      0,
      0,
      15,
      5,
      88,
      195,
    >>),
    asm.Label("rt:print_int"),
    raw(<<
      85,
      72,
      137,
      229,
      72,
      131,
      236,
      48,
      72,
      137,
      69,
      248,
      72,
      141,
      117,
      240,
      198,
      6,
      10,
      185,
      1,
      0,
      0,
      0,
      69,
      49,
      192,
      72,
      133,
      192,
    >>),
    branch(141, "rt:positive"),
    raw(<<72, 247, 216, 65, 184, 1, 0, 0, 0>>),
    asm.Label("rt:positive"),
    raw(<<65, 185, 10, 0, 0, 0>>),
    asm.Label("rt:digit"),
    raw(<<
      49,
      210,
      73,
      247,
      241,
      128,
      194,
      48,
      72,
      255,
      206,
      136,
      22,
      72,
      255,
      193,
      72,
      133,
      192,
    >>),
    branch(133, "rt:digit"),
    raw(<<77, 133, 192>>),
    branch(132, "rt:print_number"),
    raw(<<72, 255, 206, 198, 6, 45, 72, 255, 193>>),
    asm.Label("rt:print_number"),
    raw(<<
      72,
      137,
      202,
      191,
      1,
      0,
      0,
      0,
      184,
      1,
      0,
      0,
      0,
      15,
      5,
      72,
      139,
      69,
      248,
      201,
      195,
    >>),
  ]
}

// Bit arrays: [aligned object size][tag=-1][byte length][data pointer][owner][owned bytes].
// Slices retain the root owner explicitly; data pointers may be interior pointers.
fn bit_array(segments: List(#(t.Typed, a.BitMode)), state: State) -> Generated {
  use #(evaluated, saved, state) <- c.then(save_bit_values(segments, state))
  let #(length, state) = slot(state)
  let #(result, state) = slot(state)
  let allocation = [
    raw(<<49, 192>>),
    ..asm.join(bit_lengths(saved), [
      store(length),
      // Add descriptor + alignment before calling the checked arena allocator.
      raw(<<72, 131, 192, 47>>),
      branch(130, "rt:oom"),
      raw(<<72, 131, 224, 248, 72, 137, 199>>),
      call("rt:allocate"),
      store(result),
      raw(<<72, 137, 56, 72, 199, 64, 8, 255, 255, 255, 255>>),
      load(length),
      raw(<<72, 137, 193>>),
      load(result),
      raw(<<
        72,
        137,
        72,
        16,
        72,
        141,
        120,
        40,
        72,
        137,
        120,
        24,
        72,
        137,
        64,
        32,
      >>),
    ])
  ]
  Ok(#(
    asm.join(
      evaluated,
      asm.join(allocation, asm.join(write_bit_values(saved), [load(result)])),
    ),
    State(..state, needs_heap: True),
  ))
}

fn save_bit_values(
  segments: List(#(t.Typed, a.BitMode)),
  state: State,
) -> Result(#(List(asm.Part), List(#(Int, a.BitMode)), State), String) {
  case segments {
    [] -> Ok(#([], [], state))
    [#(_, a.IntegerSegment(0, _, _)), ..rest] ->
      // Upstream omits evaluation of statically zero-width integer segments.
      // The checker still validates the expression, but no runtime value is needed.
      save_bit_values(rest, state)
    [#(value, mode), ..rest] -> {
      use #(code, state) <- c.then(expression(value, state))
      let #(saved, state) = slot(state)
      use #(tail, values, state) <- c.then(save_bit_values(rest, state))
      Ok(#(
        asm.join(code, [store(saved), ..tail]),
        [#(saved, mode), ..values],
        state,
      ))
    }
  }
}

fn bit_lengths(values: List(#(Int, a.BitMode))) -> List(asm.Part) {
  case values {
    [] -> []
    [#(saved, mode), ..rest] -> {
      let add = case mode {
        a.IntegerSegment(n, _, _) -> [raw(<<72, 131, 192, n:8>>)]
        a.BitsSegment | a.BytesSegment -> [
          raw(<<72, 139, 141, saved:32-little, 72, 3, 65, 16>>),
        ]
        a.Utf8Segment -> [raw(<<72, 139, 141, saved:32-little, 72, 3, 1>>)]
      }
      asm.join(add, [branch(130, "rt:oom"), ..bit_lengths(rest)])
    }
  }
}

fn write_bit_values(values: List(#(Int, a.BitMode))) -> List(asm.Part) {
  case values {
    [] -> []
    [#(saved, mode), ..rest] -> {
      let write = case mode {
        a.IntegerSegment(n, little, _) -> [
          raw(<<72, 137, 194>>),
          ..write_integer_bytes(n, little, 0)
        ]
        a.BitsSegment | a.BytesSegment -> [
          raw(<<72, 139, 72, 16, 72, 139, 112, 24, 252, 243, 164>>),
        ]
        a.Utf8Segment -> [raw(<<72, 139, 8, 72, 141, 112, 8, 252, 243, 164>>)]
      }
      [load(saved), ..asm.join(write, write_bit_values(rest))]
    }
  }
}

fn write_integer_bytes(n: Int, little: Bool, index: Int) -> List(asm.Part) {
  case index >= n {
    True -> []
    False -> {
      let shift = case little {
        True -> index * 8
        False -> { n - index - 1 } * 8
      }
      [
        raw(<<72, 137, 208, 72, 193, 232, shift:8, 136, 7, 72, 255, 199>>),
        ..write_integer_bytes(n, little, index + 1)
      ]
    }
  }
}

fn bit_pattern(
  segments: List(#(a.Pattern, a.BitMode)),
  subject: Int,
  failure: String,
  state: State,
) -> Generated {
  use _ <- c.then(
    c.try_map(segments, fn(segment) {
      case segment.1 {
        a.Utf8Segment ->
          Error("UTF-8 codepoint pattern reached native lowering")
        _ -> Ok(Nil)
      }
    }),
  )
  let #(minimum, tail) = bit_pattern_size(segments)
  let condition = case tail {
    True -> 130
    False -> 133
  }
  let inspect = [
    load(subject),
    raw(<<72, 133, 192>>),
    branch(132, failure),
    raw(<<72, 131, 120, 8, 255>>),
    branch(133, failure),
    raw(<<72, 129, 120, 16, minimum:32-little>>),
    branch(condition, failure),
  ]
  use #(body, state) <- c.then(bit_pattern_fields(
    segments,
    0,
    subject,
    failure,
    state,
  ))
  Ok(#(asm.join(inspect, body), state))
}

fn bit_pattern_size(segments: List(#(a.Pattern, a.BitMode))) -> #(Int, Bool) {
  case segments {
    [] -> #(0, False)
    [#(_, a.Utf8Segment), ..] -> #(0, False)
    [#(_, a.BitsSegment), ..] | [#(_, a.BytesSegment), ..] -> #(0, True)
    [#(_, a.IntegerSegment(n, _, _)), ..rest] -> {
      let #(size, tail) = bit_pattern_size(rest)
      #(size + n, tail)
    }
  }
}

fn bit_pattern_fields(
  segments: List(#(a.Pattern, a.BitMode)),
  index: Int,
  subject: Int,
  failure: String,
  state: State,
) -> Generated {
  case segments {
    [] -> Ok(#([], state))
    [#(pat, mode), ..rest] -> {
      let #(value, state) = slot(state)
      let #(decode, state) = case mode {
        a.IntegerSegment(n, little, signed) -> {
          let sign = case signed, n {
            True, size if size > 0 && size < 8 -> {
              let shift = 64 - size * 8
              [raw(<<72, 193, 224, shift:8, 72, 193, 248, shift:8>>)]
            }
            False, 8 ->
              case pat {
                a.DiscardPattern -> []
                a.IntegerPattern(_) -> [
                  raw(<<72, 133, 192>>),
                  branch(136, failure),
                ]
                _ -> [raw(<<72, 133, 192>>), branch(136, "rt:overflow")]
              }
            _, _ -> []
          }
          #(
            [
              load(subject),
              raw(<<72, 139, 80, 24, 49, 192>>),
              ..asm.join(read_integer_bytes(n, little, index, 0), sign)
            ],
            state,
          )
        }
        a.Utf8Segment -> #([jump("rt:match")], state)
        a.BitsSegment | a.BytesSegment -> {
          #(
            [
              raw(<<191, 40, 0, 0, 0>>),
              call("rt:allocate"),
              raw(<<
                72,
                137,
                194,
                72,
                199,
                0,
                40,
                0,
                0,
                0,
                72,
                199,
                64,
                8,
                255,
                255,
                255,
                255,
              >>),
              load(subject),
              raw(<<
                72,
                139,
                72,
                16,
                72,
                129,
                233,
                index:32-little,
                72,
                137,
                74,
                16,
              >>),
              raw(<<
                72,
                139,
                72,
                24,
                72,
                129,
                193,
                index:32-little,
                72,
                137,
                74,
                24,
                72,
                139,
                72,
                32,
                72,
                137,
                74,
                32,
                72,
                137,
                208,
              >>),
            ],
            State(..state, needs_heap: True),
          )
        }
      }
      use #(match, state) <- c.then(pattern_code(pat, value, failure, state))
      let next = case mode {
        a.IntegerSegment(n, _, _) -> index + n
        a.BitsSegment | a.BytesSegment | a.Utf8Segment -> index
      }
      use #(tail, state) <- c.then(bit_pattern_fields(
        rest,
        next,
        subject,
        failure,
        state,
      ))
      Ok(#(asm.join(decode, [store(value), ..asm.join(match, tail)]), state))
    }
  }
}

fn read_integer_bytes(
  n: Int,
  little: Bool,
  start: Int,
  index: Int,
) -> List(asm.Part) {
  case index >= n {
    True -> []
    False -> {
      let offset = start + index
      let shift = case little {
        True -> index * 8
        False -> { n - index - 1 } * 8
      }
      [
        raw(<<
          72,
          15,
          182,
          138,
          offset:32-little,
          72,
          193,
          225,
          shift:8,
          72,
          9,
          200,
        >>),
        ..read_integer_bytes(n, little, start, index + 1)
      ]
    }
  }
}

fn string_helper(state: State, name: String) -> State {
  State(
    ..state,
    strings: [name, ..state.strings],
    needs_heap: state.needs_heap || name == "concat" || name == "drop",
  )
}

fn string_prefix(
  prefix: BitArray,
  binding: a.Pattern,
  tail: a.Pattern,
  subject: Int,
  failure: String,
  state: State,
) -> Generated {
  let #(name, state) = add_string(prefix, state)
  let state = string_helper(state, "prefix")
  let inspect = [
    load(subject),
    asm.Relative(<<72, 141, 13>>, name),
    call("rt:string_prefix"),
    raw(<<72, 133, 192>>),
    branch(132, failure),
  ]
  use #(head, state) <- c.then(case binding {
    a.DiscardPattern -> Ok(#([], state))
    _ -> {
      let #(saved, state) = slot(state)
      use #(code, state) <- c.then(pattern_code(binding, saved, failure, state))
      Ok(#([asm.Relative(<<72, 141, 5>>, name), store(saved), ..code], state))
    }
  })
  use #(rest, state) <- c.then(case tail {
    a.DiscardPattern -> Ok(#([], state))
    _ -> {
      let #(saved, state) = slot(state)
      let size = c.byte_length(prefix)
      use #(code, state) <- c.then(pattern_code(tail, saved, failure, state))
      Ok(#(
        [
          load(subject),
          raw(<<72, 199, 193, size:32-little>>),
          call("rt:string_drop"),
          store(saved),
          ..code
        ],
        string_helper(state, "drop"),
      ))
    }
  })
  Ok(#(asm.join(inspect, asm.join(head, rest)), state))
}

fn multi_case(
  subjects: List(t.Typed),
  arms: List(t.MultiArm),
  mode: TailMode,
  state: State,
) -> Generated {
  use #(evaluate, saved, state) <- c.then(save_subjects(subjects, state))
  let #(finish, state) = label(state)
  use #(body, state) <- c.then(multi_arms(arms, saved, finish, mode, state))
  Ok(#(asm.join(evaluate, asm.join(body, [asm.Label(finish)])), state))
}

fn save_subjects(
  subjects: List(t.Typed),
  state: State,
) -> Result(#(List(asm.Part), List(Int), State), String) {
  case subjects {
    [] -> Ok(#([], [], state))
    [value, ..rest] -> {
      use #(code, state) <- c.then(expression(value, state))
      let #(saved, state) = slot(state)
      use #(tail, slots, state) <- c.then(save_subjects(rest, state))
      Ok(#(asm.join(code, [store(saved), ..tail]), [saved, ..slots], state))
    }
  }
}

fn binding_slots(
  names: List(String),
  state: State,
) -> #(List(#(String, Int)), State) {
  case names {
    [] -> #([], state)
    [name, ..rest] -> {
      let #(saved, state) = slot(state)
      let #(tail, state) = binding_slots(rest, state)
      #([#(name, saved), ..tail], state)
    }
  }
}

fn multi_arms(
  arms: List(t.MultiArm),
  subjects: List(Int),
  finish: String,
  mode: TailMode,
  state: State,
) -> Generated {
  case arms {
    [] -> Ok(#([jump("rt:match")], state))
    [arm, ..rest] -> {
      let outer = state.env
      let base_slots = state.slots
      let #(canonical, state) = binding_slots(arm.bindings, state)
      let #(body_label, state) = label(state)
      let #(next_arm, state) = label(state)
      use #(matching, state) <- c.then(alternative_code(
        arm.alternatives,
        subjects,
        canonical,
        outer,
        arm.guard,
        body_label,
        next_arm,
        state,
      ))
      use #(body, state) <- c.then(tail_expression(
        arm.body,
        mode,
        State(..state, env: c.append(canonical, outer)),
      ))
      let arm_slots = state.slots
      use #(tail, state) <- c.then(multi_arms(
        rest,
        subjects,
        finish,
        mode,
        State(..state, env: outer, slots: base_slots),
      ))
      Ok(#(
        asm.join(matching, [
          asm.Label(body_label),
          ..asm.join(body, [jump(finish), asm.Label(next_arm), ..tail])
        ]),
        reserve_slots(arm_slots, state),
      ))
    }
  }
}

fn alternative_code(
  rows: List(List(a.Pattern)),
  subjects: List(Int),
  canonical: List(#(String, Int)),
  outer: List(#(String, Int)),
  guard: a.Guard(t.Typed),
  success: String,
  failure: String,
  state: State,
) -> Generated {
  case rows {
    [] -> Ok(#([jump(failure)], State(..state, env: outer)))
    [row, ..rest] -> {
      let #(next, state) = label(state)
      use #(matching, state) <- c.then(row_code(
        row,
        subjects,
        next,
        State(..state, env: outer),
      ))
      use copies <- c.then(copy_bindings(canonical, state.env))
      use #(condition, state) <- c.then(case guard {
        a.NoGuard -> Ok(#([], State(..state, env: c.append(canonical, outer))))
        a.Guard(value) -> {
          use #(code, state) <- c.then(expression(
            value,
            State(..state, env: c.append(canonical, outer)),
          ))
          Ok(#(
            asm.join(code, [raw(<<72, 133, 192>>), branch(132, next)]),
            state,
          ))
        }
      })
      use #(tail, state) <- c.then(alternative_code(
        rest,
        subjects,
        canonical,
        outer,
        guard,
        success,
        failure,
        State(..state, env: outer),
      ))
      Ok(#(
        asm.join(
          matching,
          asm.join(
            copies,
            asm.join(condition, [jump(success), asm.Label(next), ..tail]),
          ),
        ),
        state,
      ))
    }
  }
}

fn row_code(
  patterns: List(a.Pattern),
  subjects: List(Int),
  failure: String,
  state: State,
) -> Generated {
  case patterns, subjects {
    [], [] -> Ok(#([], state))
    [p, ..patterns], [saved, ..subjects] -> {
      use #(code, state) <- c.then(pattern_code(p, saved, failure, state))
      use #(tail, state) <- c.then(row_code(patterns, subjects, failure, state))
      Ok(#(asm.join(code, tail), state))
    }
    _, _ -> Error("Case pattern count does not match subject count")
  }
}

fn copy_bindings(
  canonical: List(#(String, Int)),
  env: List(#(String, Int)),
) -> Result(List(asm.Part), String) {
  case canonical {
    [] -> Ok([])
    [#(name, target), ..rest] -> {
      use source <- c.then(c.lookup(env, name))
      use tail <- c.then(copy_bindings(rest, env))
      Ok([load(source), store(target), ..tail])
    }
  }
}

fn equality_target(
  type_: a.Type,
  state: State,
) -> Result(#(String, State), String) {
  case equality_index(type_, state.equalities, 0) {
    Ok(#(id, plan)) -> Ok(#(eq_runtime.label(id, plan.root), state))
    Error(_) -> {
      use plan <- c.then(eq.plan(type_, state.globals))
      let id = c.length(state.equalities)
      let state =
        State(..state, equalities: c.append(state.equalities, [#(type_, plan)]))
      let state = case eq_runtime.uses_strings(plan) {
        True -> string_helper(state, "equal")
        False -> state
      }
      Ok(#(eq_runtime.label(id, plan.root), state))
    }
  }
}

fn equality_index(
  type_: a.Type,
  plans: List(#(a.Type, eq.Plan)),
  index: Int,
) -> Result(#(Int, eq.Plan), String) {
  case plans {
    [] -> Error("No equality plan")
    [#(t, plan), ..rest] ->
      case t == type_ {
        True -> Ok(#(index, plan))
        False -> equality_index(type_, rest, index + 1)
      }
  }
}

fn equality_helpers(
  plans: List(#(a.Type, eq.Plan)),
  index: Int,
) -> Result(List(asm.Part), String) {
  case plans {
    [] -> Ok([])
    [#(_, plan), ..rest] -> {
      use code <- c.then(eq_runtime.generate(plan, index))
      use tail <- c.then(equality_helpers(rest, index + 1))
      Ok(asm.join(code, tail))
    }
  }
}
