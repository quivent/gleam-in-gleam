import native/assembler as asm
import native/ast as a
import native/check as t
import native/core as c
import native/heap

type State {
  State(
    serial: Int,
    slots: Int,
    env: List(#(String, Int)),
    data: List(asm.Part),
    needs_heap: Bool,
  )
}

type Generated =
  Result(#(List(asm.Part), State), String)

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
  use #(bodies, state) <- c.then(function_list(
    functions,
    State(0, 0, [], [], False),
  ))
  let init = case state.needs_heap {
    True -> [call("rt:heap_init")]
    False -> []
  }
  let heap_runtime = case state.needs_heap {
    True -> heap.runtime()
    False -> []
  }
  let entry =
    c.append(init, [call("fn:main"), raw(<<49, 255, 184, 60, 0, 0, 0, 15, 5>>)])
  let parts =
    c.append(
      entry,
      c.append(
        bodies,
        c.append(runtime(), c.append(heap_runtime, c.reverse(state.data))),
      ),
    )
  asm.assemble(parts)
}

fn function_list(functions: List(t.Function), state: State) -> Generated {
  case functions {
    [] -> Ok(#([], state))
    [f, ..rest] -> {
      let env = parameter_offsets(f.parameters, c.length(f.parameters), 0)
      use #(body, state) <- c.then(statements(
        f.body,
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
          ..c.append(body, [raw(<<201, 195>>), ..tail])
        ],
        state,
      ))
    }
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
  case xs {
    [] -> Ok(#([immediate(0)], state))
    [t.Evaluate(e)] -> expression(e, state)
    [t.Evaluate(e), ..rest] -> {
      use #(code, state) <- c.then(expression(e, state))
      use #(tail, state) <- c.then(statements(rest, state))
      Ok(#(c.append(code, tail), state))
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
      use #(tail, state) <- c.then(statements(rest, state))
      Ok(#(c.append(code, [store(offset), ..c.append(bindings, tail)]), state))
    }
  }
}

fn expression(e: t.Typed, state: State) -> Generated {
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
    t.TupleNode(elements) -> {
      use #(code, state) <- c.then(arguments(elements, state))
      let n = c.length(elements)
      let size = 16 + n * 8
      let allocation = [
        raw(<<191, size:32-little>>),
        call("rt:allocate"),
        raw(<<72, 199, 0, size:32-little, 72, 199, 64, 8, 1, 0, 0, 0>>),
      ]
      Ok(#(
        c.append(code, c.append(allocation, tuple_fields(n - 1))),
        State(..state, needs_heap: True),
      ))
    }
    t.TupleIndexNode(tuple, index) -> {
      use #(code, state) <- c.then(expression(tuple, state))
      let offset = 16 + index * 8
      Ok(#(c.append(code, [raw(<<72, 139, 128, offset:32-little>>)]), state))
    }
    t.ListNode(elements, tail) -> {
      use #(code, state) <- c.then(arguments(elements, state))
      use #(tail_code, state) <- c.then(case tail {
        t.EmptyTail -> Ok(#([immediate(0)], state))
        t.ListTail(tail) -> expression(tail, state)
      })
      let n = c.length(elements)
      Ok(#(
        c.append(code, c.append(tail_code, cons_cells(n))),
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
      Ok(#(c.append(code, instructions), state))
    }
    t.BinaryNode(op, left, right) -> binary(op, left, right, state)
    t.CallNode(name, args) -> {
      use #(code, state) <- c.then(arguments(args, state))
      let cleanup = c.length(args) * 8
      Ok(#(
        c.append(code, [
          call("fn:" <> name),
          raw(<<72, 129, 196, cleanup:32-little>>),
        ]),
        state,
      ))
    }
    t.BlockNode(body) -> {
      let env = state.env
      use #(code, state) <- c.then(statements(body, state))
      Ok(#(code, State(..state, env: env)))
    }
    t.CaseNode(subject, arms) -> {
      use #(code, state) <- c.then(expression(subject, state))
      let #(offset, state) = slot(state)
      let #(finish, state) = label(state)
      use #(matches, state) <- c.then(case_arms(arms, offset, finish, state))
      Ok(#(
        c.append(code, [store(offset), ..c.append(matches, [asm.Label(finish)])]),
        state,
      ))
    }
    t.EchoNode(inner) -> {
      use #(code, state) <- c.then(expression(inner, state))
      let #(print, state) = render_echo(inner.type_, state)
      Ok(#(c.append(code, print), state))
    }
  }
}

fn arguments(args: List(t.Typed), state: State) -> Generated {
  case args {
    [] -> Ok(#([], state))
    [arg, ..rest] -> {
      use #(code, state) <- c.then(expression(arg, state))
      use #(tail, state) <- c.then(arguments(rest, state))
      Ok(#(c.append(code, [raw(<<80>>), ..tail]), state))
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
        c.append(left_code, [
          raw(<<72, 133, 192>>),
          branch(condition, finish),
          ..c.append(right_code, [asm.Label(finish)])
        ]),
        state,
      ))
    }
    _ -> {
      use #(right_code, state) <- c.then(expression(right, state))
      let #(operation, state) = operation(op, state)
      Ok(#(
        c.append(left_code, [
          raw(<<80>>),
          ..c.append(right_code, [raw(<<89>>), ..operation])
        ]),
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
          ..c.append(
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
  state: State,
) -> Generated {
  case arms {
    [] -> Ok(#([jump("rt:match")], state))
    [arm, ..rest] -> {
      let env = state.env
      let #(next, state) = label(state)
      use #(condition_code, state) <- c.then(pattern_code(
        arm.pattern,
        subject,
        next,
        state,
      ))
      use #(body, state) <- c.then(expression(arm.body, state))
      let state = State(..state, env: env)
      use #(tail, state) <- c.then(case_arms(rest, subject, finish, state))
      Ok(#(
        c.append(
          condition_code,
          c.append(body, [jump(finish), asm.Label(next), ..tail]),
        ),
        state,
      ))
    }
  }
}

fn render_echo(type_: a.Type, state: State) -> #(List(asm.Part), State) {
  case type_ {
    // The type checker rejects compound echo until structural formatting lands.
    a.TupleType(_) | a.ListType(_) | a.Unresolved -> #(
      [jump("rt:match")],
      state,
    )
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
    a.DiscardPattern -> Ok(#([], state))
    a.VariablePattern(name) ->
      Ok(#([], State(..state, env: [#(name, subject), ..state.env])))
    a.IntegerPattern(n) ->
      Ok(#(
        [load(subject), raw(<<72, 61, n:32-little>>), branch(133, failure)],
        state,
      ))
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
          ..c.append(inner, tail)
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
      Ok(#(c.append(extract, c.append(head_code, tail_code)), state))
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
