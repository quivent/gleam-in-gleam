import native/ast as a
import native/bit_options
import native/core as c
import native/coverage
import native/definitions as d
import native/equality
import native/free_names
import native/labels
import native/type_system as types

pub type Typed {
  Typed(node: Node, type_: a.Type, known_variant: Int)
}

pub type Node {
  IntegerNode(Int)
  BooleanNode(Bool)
  UnitNode
  StringNode(BitArray)
  TupleNode(List(Typed))
  BitArrayNode(List(#(Typed, a.BitMode)))
  ListNode(List(Typed), Tail)
  TupleIndexNode(Typed, Int)
  ConstructorNode(Int, List(Typed))
  FieldNode(Typed, Int, List(Int))
  VariableNode(String)
  // Bound once while checking; source names stay in the lexical environment.
  ParameterNode(offset: Int)
  UnaryNode(String, Typed)
  BinaryNode(String, Typed, Typed)
  EqualityNode(Typed, Typed, a.Type, Bool)
  CallNode(String, List(Typed))
  FunctionNode(String)
  IndirectCallNode(Typed, List(Typed))
  ClosureNode(List(#(String, a.Type)), List(Statement), List(#(String, Int)))
  BlockNode(List(Statement))
  CaseNode(Typed, List(Arm))
  MultiCaseNode(List(Typed), List(MultiArm))
  EchoNode(Typed)
}

pub type Tail {
  EmptyTail
  ListTail(Typed)
}

pub type Statement {
  Bind(a.Pattern, Typed)
  Evaluate(Typed)
}

pub type MultiArm {
  MultiArm(
    alternatives: List(List(a.Pattern)),
    bindings: List(String),
    guard: a.Guard(Typed),
    body: Typed,
  )
}

pub type Arm {
  Arm(pattern: a.Pattern, guard: a.Guard(Typed), body: Typed)
}

pub type Function {
  Function(
    name: String,
    parameters: List(#(String, a.Type)),
    result: a.Type,
    body: List(Statement),
  )
}

type Environment =
  List(#(String, Local))

type Local {
  Local(type_: a.Type, known_variant: Int, read: Node)
}

fn plain(node: Node, type_: a.Type) -> Typed {
  Typed(node, type_, 0)
}

type Globals =
  d.Context

fn equal(actual: a.Type, expected: a.Type) -> Result(Nil, String) {
  case merge_type(actual, expected) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

fn merge_type(actual: a.Type, expected: a.Type) -> Result(a.Type, String) {
  types.merge(actual, expected)
}

pub fn type_name(t: a.Type) -> String {
  types.name(t)
}

pub fn module(module: a.Module) -> Result(List(Function), String) {
  use _ <- c.then(headers(module))
  use globals <- c.then(d.collect(module))
  check_functions(module, globals)
}

pub fn module_with_context(
  module: a.Module,
  globals: d.Context,
) -> Result(List(Function), String) {
  use _ <- c.then(headers(module))
  check_functions(module, globals)
}

fn headers(module: a.Module) -> Result(Nil, String) {
  use _ <- c.then(case module.imports, module.aliases {
    [], [] -> Ok(Nil)
    _, _ ->
      Error("Project imports/aliases must be resolved before type checking")
  })
  use _ <- c.then(signatures(module.functions, []))
  Ok(Nil)
}

fn check_functions(
  module: a.Module,
  globals: d.Context,
) -> Result(List(Function), String) {
  use main <- c.then(c.lookup(globals.functions, "main"))
  case main.parameters {
    [] ->
      c.try_map(module.functions, fn(f) {
        case function(f, globals) {
          Ok(value) -> Ok(value)
          Error(e) -> Error("In function " <> f.name <> ": " <> e)
        }
      })
    _ -> Error("main must have no parameters")
  }
}

fn signatures(
  functions: List(a.Function),
  acc: List(#(String, a.Function)),
) -> Result(List(#(String, a.Function)), String) {
  case functions {
    [] -> Ok(acc)
    [f, ..rest] ->
      case c.lookup(acc, f.name) {
        Ok(_) -> Error("Duplicate function: " <> f.name)
        Error(_) -> {
          use _ <- c.then(unique_parameters(f.parameters, []))
          signatures(rest, [#(f.name, f), ..acc])
        }
      }
  }
}

fn unique_parameters(
  parameters: List(#(String, a.Type)),
  seen: List(#(String, a.Type)),
) -> Result(Nil, String) {
  case parameters {
    [] -> Ok(Nil)
    [#(name, t), ..rest] ->
      case c.discarded_name(name) {
        True -> unique_parameters(rest, seen)
        False ->
          case c.lookup(seen, name) {
            Ok(_) -> Error("Duplicate parameter: " <> name)
            Error(_) -> unique_parameters(rest, [#(name, t), ..seen])
          }
      }
  }
}

// The current native calling convention binds incoming values at +16 onward,
// in reverse push order. This fuses location binding into the required lexical
// environment construction; codegen no longer builds a second parameter map.
fn parameter_environment(
  parameters: List(#(String, a.Type)),
  offset: Int,
) -> Environment {
  case parameters {
    [] -> []
    [#(name, type_), ..rest] -> [
      #(name, Local(type_, 0, ParameterNode(offset))),
      ..parameter_environment(rest, offset - 8)
    ]
  }
}

fn function(f: a.Function, globals: Globals) -> Result(Function, String) {
  let variables =
    types.variables(c.append(c.map(f.parameters, fn(p) { p.1 }), [f.result]))
  let globals =
    d.Context(
      ..globals,
      function_parameters: variables,
      current_function: f.name,
    )
  use #(body, result_type) <- c.then(statements(
    f.body,
    parameter_environment(f.parameters, 16 + { c.length(f.parameters) - 1 } * 8),
    globals,
    f.result,
  ))
  use _ <- c.then(equal(result_type, f.result))
  Ok(Function(f.name, f.parameters, f.result, body))
}

fn statements(
  xs: List(a.Statement),
  env: Environment,
  globals: Globals,
  expected: a.Type,
) -> Result(#(List(Statement), a.Type), String) {
  case xs {
    [] -> Ok(#([], a.Unit))
    [a.Bind(pat, annotation, value), ..rest] -> {
      let expected_value = case annotation {
        a.Inferred -> a.Unresolved
        a.Annotated(t) -> t
      }
      use typed <- c.then(expression_expected(
        value,
        env,
        globals,
        expected_value,
      ))
      use typed <- c.then(case annotation {
        a.Inferred -> Ok(typed)
        a.Annotated(t) -> {
          use _ <- c.then(d.validate_type(t, globals))
          use _ <- c.then(equal(typed.type_, t))
          Ok(Typed(..typed, type_: t))
        }
      })
      use #(pat, next_env) <- c.then(pattern(
        pat,
        typed.type_,
        env,
        globals,
        typed.known_variant,
      ))
      use _ <- c.then(
        case covers_known(pat, typed.type_, typed.known_variant, globals) {
          True -> Ok(Nil)
          False ->
            Error(
              "Refutable let pattern: use case (let assert is not implemented)",
            )
        },
      )
      case rest {
        [] ->
          Error("A function/block must end in an expression, not an assignment")
        _ -> {
          use #(tail, t) <- c.then(statements(rest, next_env, globals, expected))
          Ok(#([Bind(pat, typed), ..tail], t))
        }
      }
    }
    [a.Evaluate(value), ..rest] -> {
      use typed <- c.then(case rest {
        [] -> expression_expected(value, env, globals, expected)
        _ -> expression(value, env, globals)
      })
      case rest {
        [] -> Ok(#([Evaluate(typed)], typed.type_))
        _ -> {
          use #(tail, t) <- c.then(statements(rest, env, globals, expected))
          Ok(#([Evaluate(typed), ..tail], t))
        }
      }
    }
  }
}

fn expression(
  e: a.Expression,
  env: Environment,
  globals: Globals,
) -> Result(Typed, String) {
  case e {
    a.IntegerLiteral(n) -> Ok(plain(IntegerNode(n), a.Integer))
    a.BooleanLiteral(b) -> Ok(plain(BooleanNode(b), a.Boolean))
    a.UnitLiteral -> Ok(plain(UnitNode, a.Unit))
    a.StringLiteral(s) -> Ok(plain(StringNode(s), a.StringType))
    a.BitArrayLiteral(segments) -> {
      use segments <- c.then(
        c.try_map(segments, fn(segment) {
          use mode <- c.then(case segment.value, segment.options {
            a.StringLiteral(_), [] -> Ok(a.Utf8Segment)
            _, _ -> bit_options.mode(segment.options, False)
          })
          use value <- c.then(expression(segment.value, env, globals))
          use _ <- c.then(equal(value.type_, bit_segment_type(mode)))
          Ok(#(value, mode))
        }),
      )
      Ok(plain(BitArrayNode(segments), a.BitArrayType))
    }
    a.TupleLiteral(elements) -> {
      use typed <- c.then(
        c.try_map(elements, fn(e) { expression(e, env, globals) }),
      )
      Ok(plain(TupleNode(typed), a.TupleType(c.map(typed, fn(e) { e.type_ }))))
    }
    a.TupleIndex(tuple, index) -> {
      use tuple <- c.then(expression(tuple, env, globals))
      case tuple.type_ {
        a.TupleType(elements) -> {
          use type_ <- c.then(c.nth(elements, index))
          Ok(plain(TupleIndexNode(tuple, index), type_))
        }
        _ -> Error("Tuple index requires a tuple")
      }
    }
    a.ListLiteral(elements, rest) -> {
      use elements <- c.then(
        c.try_map(elements, fn(e) { expression(e, env, globals) }),
      )
      use tail <- c.then(case rest {
        a.NoRest -> Ok(EmptyTail)
        a.Rest(e) -> {
          use typed <- c.then(expression(e, env, globals))
          case typed.type_ {
            a.ListType(_) -> Ok(ListTail(typed))
            _ -> Error("List spread tail must be a list")
          }
        }
      })
      let initial = case tail {
        EmptyTail -> a.Unresolved
        ListTail(t) ->
          case t.type_ {
            a.ListType(t) -> t
            _ -> a.Unresolved
          }
      }
      use element <- c.then(list_element_type(elements, initial))
      Ok(plain(ListNode(elements, tail), a.ListType(element)))
    }
    a.Variable(name) -> {
      use _ <- c.then(case c.discarded_name(name) {
        True -> Error("Discarded variable cannot be read")
        False -> Ok(Nil)
      })
      case c.uppercase_name(name) {
        True -> constructor(name, [], env, globals, False, a.Unresolved)
        False -> {
          case c.lookup(env, name) {
            Ok(local) -> Ok(Typed(local.read, local.type_, local.known_variant))
            Error(_) -> {
              use f <- c.then(c.lookup(globals.functions, name))
              let signature =
                a.FunctionType(c.map(f.parameters, fn(p) { p.1 }), f.result)
              case types.variables([signature]) {
                [] -> Ok(plain(FunctionNode(name), signature))
                _ ->
                  Error(
                    "Polymorphic named function values are not implemented; use a direct call",
                  )
              }
            }
          }
        }
      }
    }
    a.Unary(op, inner) -> {
      use typed <- c.then(expression(inner, env, globals))
      let t = case op {
        "-" -> a.Integer
        _ -> a.Boolean
      }
      use _ <- c.then(equal(typed.type_, t))
      Ok(plain(UnaryNode(op, typed), t))
    }
    a.Binary(op, left, right) -> {
      use left <- c.then(expression(left, env, globals))
      use right <- c.then(expression(right, env, globals))
      case op == "==" || op == "!=" {
        True -> {
          use common <- c.then(merge_type(left.type_, right.type_))
          use _ <- c.then(equality.plan(common, globals))
          case common {
            a.Integer | a.Boolean | a.Unit | a.StringType ->
              Ok(plain(BinaryNode(op, left, right), a.Boolean))
            _ ->
              Ok(plain(EqualityNode(left, right, common, op == "!="), a.Boolean))
          }
        }
        False -> {
          use result <- c.then(binary_type(op, left.type_, right.type_))
          Ok(plain(BinaryNode(op, left, right), result))
        }
      }
    }
    a.Call(name, args) -> named_call(name, args, env, globals)
    a.QualifiedRecordUpdate(_, _, _, _) ->
      Error("Unresolved module record update")
    a.RecordUpdate(name, target, args) ->
      record_update(name, target, args, env, globals)
    a.Apply(a.ModuleFallbackField(target, field, fallback), args) -> {
      use target <- c.then(expression(target, env, globals))
      case field_access(target, field, globals) {
        Ok(field) -> indirect_source_call(field, args, env, globals)
        Error(_) -> {
          use name <- c.then(fallback)
          named_call(name, args, env, globals)
        }
      }
    }
    a.Apply(target, args) -> {
      use target <- c.then(expression(target, env, globals))
      indirect_source_call(target, args, env, globals)
    }
    a.Lambda(params, annotation, body) ->
      lambda(params, annotation, body, env, globals, a.Unresolved)
    a.ModuleFallbackField(target, field, fallback) -> {
      use target <- c.then(expression(target, env, globals))
      case field_access(target, field, globals) {
        Ok(field) -> Ok(field)
        Error(_) -> {
          use name <- c.then(fallback)
          expression(a.Variable(name), env, globals)
        }
      }
    }
    a.FieldAccess(target, field) -> {
      use target <- c.then(expression(target, env, globals))
      field_access(target, field, globals)
    }
    a.Block(body) -> {
      use #(body, t) <- c.then(statements(body, env, globals, a.Unresolved))
      Ok(plain(BlockNode(body), t))
    }
    a.Echo(inner) -> {
      use typed <- c.then(expression(inner, env, globals))
      case typed.type_ {
        a.BitArrayType
        | a.TupleType(_)
        | a.ListType(_)
        | a.NamedType(_)
        | a.AppliedType(_, _)
        | a.VariableType(_)
        | a.FunctionType(_, _)
        | a.Unresolved ->
          Error("Compound-value echo formatting is not implemented yet")
        _ -> Ok(plain(EchoNode(typed), typed.type_))
      }
    }
    a.CaseSubjects(subjects, arms) ->
      multi_case(subjects, arms, env, globals, a.Unresolved)
    a.Case(subject, arms) ->
      case_expression(subject, arms, env, globals, a.Unresolved)
  }
}

fn case_expression(
  subject: a.Expression,
  arms: List(a.Arm),
  env: Environment,
  globals: Globals,
  expected: a.Type,
) -> Result(Typed, String) {
  use subject <- c.then(expression(subject, env, globals))
  use arms <- c.then(
    c.try_map(arms, fn(arm) {
      use #(pat, branch_env) <- c.then(pattern(
        arm.pattern,
        subject.type_,
        env,
        globals,
        subject.known_variant,
      ))
      use body <- c.then(expression_expected(
        arm.body,
        branch_env,
        globals,
        expected,
      ))
      use guard <- c.then(case arm.guard {
        a.NoGuard -> Ok(a.NoGuard)
        a.Guard(source) -> {
          use _ <- c.then(guard_source(source))
          use value <- c.then(expression(source, branch_env, globals))
          use _ <- c.then(equal(value.type_, a.Boolean))
          Ok(a.Guard(value))
        }
      })
      Ok(Arm(pat, guard, body))
    }),
  )
  use _ <- c.then(case_exhaustive(unguarded(arms), subject, globals))
  case arms {
    [] -> Error("Empty case")
    [first, ..rest] -> {
      use result <- c.then(branch_type(rest, first.body.type_))
      Ok(plain(CaseNode(subject, arms), result))
    }
  }
}

fn expression_expected(
  e: a.Expression,
  env: Environment,
  globals: Globals,
  expected: a.Type,
) -> Result(Typed, String) {
  case e {
    a.CaseSubjects(subjects, arms) ->
      multi_case(subjects, arms, env, globals, expected)
    a.Case(subject, arms) ->
      case_expression(subject, arms, env, globals, expected)
    a.Call(name, args) ->
      case c.uppercase_name(name) {
        True -> constructor(name, args, env, globals, True, expected)
        False -> expression(e, env, globals)
      }
    a.Lambda(params, annotation, body) ->
      lambda(params, annotation, body, env, globals, expected)
    a.Block(body) -> {
      use #(body, t) <- c.then(statements(body, env, globals, expected))
      Ok(plain(BlockNode(body), t))
    }
    _ -> expression(e, env, globals)
  }
}

type PreparedArgument {
  Ready(Typed)
  Pending(a.Expression, a.Type)
}

fn context_arguments(
  args: List(a.Expression),
  formals: List(a.Type),
  initial: types.Bindings,
  env: Environment,
  globals: Globals,
) -> Result(#(List(Typed), types.Bindings), String) {
  use #(prepared, bindings) <- c.then(prepare_arguments(
    args,
    formals,
    initial,
    env,
    globals,
  ))
  finish_arguments(prepared, bindings, env, globals)
}

fn prepare_arguments(
  args: List(a.Expression),
  formals: List(a.Type),
  bindings: types.Bindings,
  env: Environment,
  globals: Globals,
) -> Result(#(List(PreparedArgument), types.Bindings), String) {
  case args, formals {
    [], [] -> Ok(#([], bindings))
    [arg, ..args], [formal, ..formals] -> {
      use #(prepared, bindings) <- c.then(case arg {
        a.Lambda(_, _, _) -> Ok(#(Pending(arg, formal), bindings))
        _ -> {
          use typed <- c.then(expression(arg, env, globals))
          use bindings <- c.then(types.infer(formal, typed.type_, bindings))
          Ok(#(Ready(typed), bindings))
        }
      })
      use #(rest, bindings) <- c.then(prepare_arguments(
        args,
        formals,
        bindings,
        env,
        globals,
      ))
      Ok(#([prepared, ..rest], bindings))
    }
    _, _ -> Error("Function argument count mismatch")
  }
}

fn finish_arguments(
  args: List(PreparedArgument),
  bindings: types.Bindings,
  env: Environment,
  globals: Globals,
) -> Result(#(List(Typed), types.Bindings), String) {
  case args {
    [] -> Ok(#([], bindings))
    [arg, ..rest] -> {
      use #(typed, bindings) <- c.then(case arg {
        Ready(typed) -> Ok(#(typed, bindings))
        Pending(source, formal) -> {
          use expected <- c.then(types.substitute(formal, bindings))
          use typed <- c.then(expression_expected(
            source,
            env,
            globals,
            expected,
          ))
          use bindings <- c.then(types.infer(formal, typed.type_, bindings))
          Ok(#(typed, bindings))
        }
      })
      use #(rest, bindings) <- c.then(finish_arguments(
        rest,
        bindings,
        env,
        globals,
      ))
      Ok(#([typed, ..rest], bindings))
    }
  }
}

fn lambda(
  params: List(a.LambdaParameter),
  annotation: a.Annotation,
  body: List(a.Statement),
  env: Environment,
  globals: Globals,
  expected: a.Type,
) -> Result(Typed, String) {
  use #(expected_params, expected_result) <- c.then(case expected {
    a.FunctionType(params, result) -> Ok(#(params, result))
    a.Unresolved -> Ok(#(c.map(params, fn(_) { a.Unresolved }), a.Unresolved))
    _ -> Error("Anonymous function requires a function type context")
  })
  use parameter_types <- c.then(lambda_types(params, expected_params, globals))
  let names = all_parameter_names(params)
  use _ <- c.then(unique_lambda_names(names, []))
  let #(parameters, bindings) = lower_parameters(params, parameter_types, 0)
  let result_context = case annotation {
    a.Inferred -> expected_result
    a.Annotated(t) -> t
  }
  use _ <- c.then(case annotation {
    a.Inferred -> Ok(Nil)
    a.Annotated(t) -> d.validate_type(t, globals)
  })
  let parameter_env =
    parameter_environment(parameters, 16 + { c.length(parameters) - 1 } * 8)
  let captures = actual_captures(free_names.names(body, names), env)
  // Captures belong to the new frame. Their incoming parent offsets are used
  // only when constructing the descriptor, never from inside the closure.
  use captured_env <- c.then(
    c.try_map(captures, fn(entry) {
      use local <- c.then(c.lookup(env, entry.0))
      Ok(#(entry.0, Local(..local, read: VariableNode(entry.0))))
    }),
  )
  use #(typed_body, result) <- c.then(statements(
    c.append(bindings, body),
    c.append(parameter_env, captured_env),
    globals,
    result_context,
  ))
  use result <- c.then(types.merge(result, result_context))
  use _ <- c.then(equal(result, expected_result))
  Ok(plain(
    ClosureNode(parameters, typed_body, captures),
    a.FunctionType(parameter_types, result),
  ))
}

fn lambda_types(
  params: List(a.LambdaParameter),
  expected: List(a.Type),
  globals: Globals,
) -> Result(List(a.Type), String) {
  case params, expected {
    [], [] -> Ok([])
    [p, ..params], [t, ..expected] -> {
      use type_ <- c.then(case p.annotation {
        a.Annotated(type_) -> {
          use _ <- c.then(d.validate_type(type_, globals))
          use _ <- c.then(equal(type_, t))
          Ok(type_)
        }
        a.Inferred ->
          case resolved(t) {
            True -> Ok(t)
            False ->
              Error(
                "Anonymous parameter needs an annotation or stronger type context",
              )
          }
      })
      use rest <- c.then(lambda_types(params, expected, globals))
      Ok([type_, ..rest])
    }
    _, _ -> Error("Anonymous function parameter count mismatch")
  }
}

fn resolved(t: a.Type) -> Bool {
  case t {
    a.Unresolved -> False
    a.ListType(t) -> resolved(t)
    a.TupleType(ts) | a.AppliedType(_, ts) -> all_resolved(ts)
    a.FunctionType(ps, r) -> all_resolved([r, ..ps])
    _ -> True
  }
}

fn all_resolved(ts: List(a.Type)) -> Bool {
  case ts {
    [] -> True
    [t, ..rest] -> resolved(t) && all_resolved(rest)
  }
}

fn all_parameter_names(params: List(a.LambdaParameter)) -> List(String) {
  case params {
    [] -> []
    [p, ..rest] ->
      c.append(free_names.pattern_names(p.pattern), all_parameter_names(rest))
  }
}

fn unique_lambda_names(
  names: List(String),
  seen: List(#(String, Nil)),
) -> Result(Nil, String) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case c.lookup(seen, name) {
        Ok(_) -> Error("Duplicate anonymous parameter: " <> name)
        Error(_) -> unique_lambda_names(rest, [#(name, Nil), ..seen])
      }
  }
}

fn lower_parameters(
  params: List(a.LambdaParameter),
  types: List(a.Type),
  index: Int,
) -> #(List(#(String, a.Type)), List(a.Statement)) {
  case params, types {
    [p, ..params], [t, ..types] -> {
      let name = "$arg:" <> c.decimal(index)
      let #(tail, bindings) = lower_parameters(params, types, index + 1)
      #([#(name, t), ..tail], [
        a.Bind(p.pattern, a.Annotated(t), a.Variable(name)),
        ..bindings
      ])
    }
    _, _ -> #([], [])
  }
}

fn actual_captures(
  names: List(String),
  env: Environment,
) -> List(#(String, Int)) {
  case names {
    [] -> []
    [name, ..rest] ->
      case c.lookup(env, name) {
        Ok(local) -> {
          let offset = case local.read {
            ParameterNode(offset) -> offset
            _ -> 0
          }
          [#(name, offset), ..actual_captures(rest, env)]
        }
        Error(_) -> actual_captures(rest, env)
      }
  }
}

fn binary_type(
  op: String,
  left: a.Type,
  right: a.Type,
) -> Result(a.Type, String) {
  case op {
    "<>" -> {
      use _ <- c.then(equal(left, a.StringType))
      use _ <- c.then(equal(right, a.StringType))
      Ok(a.StringType)
    }
    "&&" | "||" -> {
      use _ <- c.then(equal(left, a.Boolean))
      use _ <- c.then(equal(right, a.Boolean))
      Ok(a.Boolean)
    }

    _ -> {
      use _ <- c.then(equal(left, a.Integer))
      use _ <- c.then(equal(right, a.Integer))
      case op {
        "<" | "<=" | ">" | ">=" -> Ok(a.Boolean)
        _ -> Ok(a.Integer)
      }
    }
  }
}

fn source_arguments(
  args: List(a.Argument),
) -> Result(List(a.Expression), String) {
  c.try_map(args, fn(arg) {
    case arg.label {
      "" -> Ok(arg.value)
      _ -> Error("Labelled function calls are not implemented yet")
    }
  })
}

fn named_call(
  name: String,
  source_args: List(a.Argument),
  env: Environment,
  globals: Globals,
) -> Result(Typed, String) {
  case c.uppercase_name(name) {
    True -> constructor(name, source_args, env, globals, True, a.Unresolved)
    False ->
      case c.lookup(env, name) {
        Ok(local) ->
          case c.discarded_name(name) {
            True -> Error("Discarded variable cannot be read")
            False ->
              indirect_source_call(
                Typed(local.read, local.type_, local.known_variant),
                source_args,
                env,
                globals,
              )
          }
        Error(_) -> {
          use f <- c.then(c.lookup(globals.functions, name))
          use args <- c.then(source_arguments(source_args))
          let formals = c.map(f.parameters, fn(p) { p.1 })
          let variables = case name == globals.current_function {
            True -> []
            False -> types.variables(c.append(formals, [f.result]))
          }
          let initial = c.map(variables, fn(n) { #(n, a.Unresolved) })
          use #(args, bindings) <- c.then(context_arguments(
            args,
            formals,
            initial,
            env,
            globals,
          ))
          use result <- c.then(types.substitute(f.result, bindings))
          Ok(plain(CallNode(name, args), result))
        }
      }
  }
}

fn indirect_source_call(
  target: Typed,
  source_args: List(a.Argument),
  env: Environment,
  globals: Globals,
) -> Result(Typed, String) {
  case target.type_ {
    a.FunctionType(params, result) -> {
      use args <- c.then(source_arguments(source_args))
      use #(args, _) <- c.then(context_arguments(args, params, [], env, globals))
      Ok(plain(IndirectCallNode(target, args), result))
    }
    _ -> Error("Value is not a function")
  }
}

fn pattern(
  p: a.Pattern,
  t: a.Type,
  env: Environment,
  globals: Globals,
  known: Int,
) -> Result(#(a.Pattern, Environment), String) {
  use resolved <- c.then(resolve_pattern(p, t, globals))
  use bindings <- c.then(pattern_bindings(resolved, t, []))
  Ok(#(resolved, c.append(known_bindings(resolved, t, known, bindings), env)))
}

fn pattern_variant(p: a.Pattern, fallback: Int) -> Int {
  case a.without_alias(p) {
    a.CheckedConstructorPattern(tag, _) -> tag
    _ -> fallback
  }
}

fn known_bindings(
  p: a.Pattern,
  t: a.Type,
  known: Int,
  bindings: Environment,
) -> Environment {
  case p {
    a.VariablePattern(name) ->
      c.put(bindings, name, Local(t, known, VariableNode(name)))
    a.AliasPattern(inner, name) ->
      c.put(
        known_bindings(inner, t, known, bindings),
        name,
        Local(t, pattern_variant(inner, known), VariableNode(name)),
      )
    _ -> bindings
  }
}

fn constructor(
  name: String,
  args: List(a.Argument),
  env: Environment,
  globals: Globals,
  called: Bool,
  expected: a.Type,
) -> Result(Typed, String) {
  use definition <- c.then(c.lookup(globals.constructors, name))
  use _ <- c.then(case definition.fields, called {
    [], True ->
      Error("Zero-field constructor is a value, not a function: " <> name)
    _, _ -> Ok(Nil)
  })
  use ordered <- c.then(labels.order(
    c.map(args, fn(arg) { #(arg.label, arg.value) }),
    definition.labels,
    labels.RejectMissing,
  ))
  use initial <- c.then(case expected {
    a.AppliedType(owner, args) if owner == definition.owner ->
      types.bindings(definition.parameters, args)
    _ -> Ok(c.map(definition.parameters, fn(n) { #(n, a.Unresolved) }))
  })
  use #(args, bindings) <- c.then(context_arguments(
    ordered,
    definition.fields,
    initial,
    env,
    globals,
  ))
  use parameters <- c.then(
    c.try_map(definition.parameters, fn(n) { c.lookup(bindings, n) }),
  )
  Ok(Typed(
    ConstructorNode(definition.tag, args),
    types.apply(definition.owner, parameters),
    definition.tag,
  ))
}

fn constructor_type_arguments(
  definition: d.Constructor,
  t: a.Type,
) -> Result(List(a.Type), String) {
  case t {
    a.NamedType(n) if n == definition.owner -> Ok([])
    a.AppliedType(n, args) if n == definition.owner -> Ok(args)
    a.Unresolved -> Ok(c.map(definition.parameters, fn(_) { a.Unresolved }))
    _ ->
      Error(
        "Type mismatch: expected "
        <> definition.owner
        <> ", found "
        <> types.name(t),
      )
  }
}

fn field_access(
  target: Typed,
  field: String,
  globals: Globals,
) -> Result(Typed, String) {
  use owner <- c.then(case target.type_ {
    a.NamedType(name) | a.AppliedType(name, _) -> Ok(name)
    _ -> Error("Record field access requires a custom type")
  })
  use definition <- c.then(c.lookup(globals.custom_types, owner))
  use constructors <- c.then(field_constructors(
    definition.variants,
    target.known_variant,
    globals,
  ))
  case constructors {
    [] -> Error("No possible constructor for record field")
    [first, ..rest] -> {
      use index <- c.then(labels.index(first.labels, field))
      use formal <- c.then(c.nth(first.fields, index))
      use _ <- c.then(consistent_fields(rest, index, formal, field))
      use args <- c.then(constructor_type_arguments(first, target.type_))
      use bindings <- c.then(types.bindings(first.parameters, args))
      use type_ <- c.then(types.substitute(formal, bindings))
      Ok(plain(
        FieldNode(target, index, c.map(constructors, fn(ctor) { ctor.tag })),
        type_,
      ))
    }
  }
}

fn field_constructors(
  variants: List(a.Variant),
  known: Int,
  globals: Globals,
) -> Result(List(d.Constructor), String) {
  case variants {
    [] -> Ok([])
    [variant, ..rest] -> {
      use ctor <- c.then(c.lookup(globals.constructors, variant.name))
      use tail <- c.then(field_constructors(rest, known, globals))
      case known == 0 || ctor.tag == known {
        True -> Ok([ctor, ..tail])
        False -> Ok(tail)
      }
    }
  }
}

fn consistent_fields(
  constructors: List(d.Constructor),
  index: Int,
  formal: a.Type,
  field: String,
) -> Result(Nil, String) {
  case constructors {
    [] -> Ok(Nil)
    [ctor, ..rest] -> {
      use other <- c.then(labels.index(ctor.labels, field))
      use type_ <- c.then(c.nth(ctor.fields, other))
      case other == index && type_ == formal {
        True -> consistent_fields(rest, index, formal, field)
        False ->
          Error(
            "Record field must have the same position and declared type across variants",
          )
      }
    }
  }
}

fn resolve_pattern(
  p: a.Pattern,
  t: a.Type,
  globals: Globals,
) -> Result(a.Pattern, String) {
  case p {
    a.AliasPattern(inner, name) -> {
      use inner <- c.then(resolve_pattern(inner, t, globals))
      Ok(a.AliasPattern(inner, name))
    }
    a.BitArrayPattern(segments) -> {
      use _ <- c.then(equal(t, a.BitArrayType))
      use segments <- c.then(bit_patterns(segments, globals))
      Ok(a.CheckedBitArrayPattern(segments))
    }
    a.CheckedBitArrayPattern(_) ->
      Error("Internal checked bit-array pattern in source AST")
    a.ModuleConstructorPattern(_, _, _, _) ->
      Error("Unresolved module constructor pattern")
    a.ConstructorPattern(name, fields, spread) -> {
      use definition <- c.then(c.lookup(globals.constructors, name))
      use _ <- c.then(
        case !spread && c.length(fields) != c.length(definition.fields) {
          True -> Error("Constructor pattern arity mismatch")
          False -> Ok(Nil)
        },
      )
      let missing = case spread {
        True -> labels.FillMissing(a.DiscardPattern)
        False -> labels.RejectMissing
      }
      use fields <- c.then(labels.order(
        c.map(fields, fn(field) { #(field.label, field.pattern) }),
        definition.labels,
        missing,
      ))
      use args <- c.then(constructor_type_arguments(definition, t))
      use bindings <- c.then(types.bindings(definition.parameters, args))
      use field_types <- c.then(
        c.try_map(definition.fields, fn(t) { types.substitute(t, bindings) }),
      )
      use fields <- c.then(resolve_fields(fields, field_types, globals))
      Ok(a.CheckedConstructorPattern(definition.tag, fields))
    }
    a.CheckedConstructorPattern(_, _) ->
      Error("Internal checked pattern in source AST")
    a.TuplePattern(patterns) ->
      case t {
        a.TupleType(types) -> {
          use fields <- c.then(resolve_fields(patterns, types, globals))
          Ok(a.TuplePattern(c.map(fields, fn(field) { field.0 })))
        }
        _ -> Error("Tuple pattern requires a tuple")
      }
    a.ListPattern(patterns, tail) ->
      case t {
        a.ListType(element) -> {
          use patterns <- c.then(
            c.try_map(patterns, fn(p) { resolve_pattern(p, element, globals) }),
          )
          use tail <- c.then(case tail {
            a.NoPatternRest -> Ok(a.NoPatternRest)
            a.RestPattern(p) -> {
              use p <- c.then(resolve_pattern(p, t, globals))
              Ok(a.RestPattern(p))
            }
          })
          Ok(a.ListPattern(patterns, tail))
        }
        _ -> Error("List pattern requires a list")
      }
    _ -> Ok(p)
  }
}

fn resolve_fields(
  patterns: List(a.Pattern),
  types: List(a.Type),
  globals: Globals,
) -> Result(List(#(a.Pattern, a.Type)), String) {
  case patterns, types {
    [], [] -> Ok([])
    [p, ..patterns], [t, ..types] -> {
      use p <- c.then(resolve_pattern(p, t, globals))
      use rest <- c.then(resolve_fields(patterns, types, globals))
      Ok([#(p, t), ..rest])
    }
    _, _ -> Error("Tuple/constructor arity mismatch in pattern")
  }
}

fn pattern_bindings(
  p: a.Pattern,
  t: a.Type,
  bindings: Environment,
) -> Result(Environment, String) {
  case p {
    a.AliasPattern(inner, name) -> {
      use bindings <- c.then(pattern_bindings(inner, t, bindings))
      use bindings <- c.then(pattern_bindings(
        a.VariablePattern(name),
        t,
        bindings,
      ))
      Ok(c.put(
        bindings,
        name,
        Local(t, pattern_variant(inner, 0), VariableNode(name)),
      ))
    }
    a.StringPattern(_) -> {
      use _ <- c.then(equal(t, a.StringType))
      Ok(bindings)
    }
    a.StringPrefixPattern(_, binding, tail) -> {
      use _ <- c.then(equal(t, a.StringType))
      use bindings <- c.then(pattern_bindings(binding, t, bindings))
      pattern_bindings(tail, t, bindings)
    }
    a.BitArrayPattern(_) -> Error("Unresolved bit-array pattern")
    a.CheckedBitArrayPattern(fields) ->
      checked_field_bindings(
        c.map(fields, fn(f) { #(f.0, bit_segment_type(f.1)) }),
        bindings,
      )
    a.ModuleConstructorPattern(_, _, _, _) ->
      Error("Unresolved module constructor pattern")
    a.ConstructorPattern(_, _, _) -> Error("Unresolved constructor pattern")
    a.CheckedConstructorPattern(_, fields) ->
      checked_field_bindings(fields, bindings)
    a.DiscardPattern -> Ok(bindings)
    a.VariablePattern(name) ->
      case c.lookup(bindings, name) {
        Ok(_) -> Error("Duplicate variable in pattern: " <> name)
        Error(_) -> Ok([#(name, Local(t, 0, VariableNode(name))), ..bindings])
      }
    a.IntegerPattern(_) -> {
      use _ <- c.then(equal(t, a.Integer))
      Ok(bindings)
    }
    a.BooleanPattern(_) -> {
      use _ <- c.then(equal(t, a.Boolean))
      Ok(bindings)
    }
    a.TuplePattern(patterns) ->
      case t {
        a.TupleType(types) -> tuple_bindings(patterns, types, bindings)
        _ -> Error("Tuple pattern requires a tuple")
      }
    a.ListPattern(patterns, tail) ->
      case t {
        a.ListType(element) -> {
          use bindings <- c.then(list_bindings(patterns, element, bindings))
          case tail {
            a.NoPatternRest -> Ok(bindings)
            a.RestPattern(p) -> pattern_bindings(p, t, bindings)
          }
        }
        _ -> Error("List pattern requires a list")
      }
  }
}

fn checked_field_bindings(
  fields: List(#(a.Pattern, a.Type)),
  bindings: Environment,
) -> Result(Environment, String) {
  case fields {
    [] -> Ok(bindings)
    [#(p, t), ..rest] -> {
      use bindings <- c.then(pattern_bindings(p, t, bindings))
      checked_field_bindings(rest, bindings)
    }
  }
}

fn tuple_bindings(
  patterns: List(a.Pattern),
  types: List(a.Type),
  bindings: Environment,
) -> Result(Environment, String) {
  case patterns, types {
    [], [] -> Ok(bindings)
    [p, ..patterns], [t, ..types] -> {
      use bindings <- c.then(pattern_bindings(p, t, bindings))
      tuple_bindings(patterns, types, bindings)
    }
    _, _ -> Error("Tuple arity mismatch in pattern")
  }
}

fn list_bindings(
  patterns: List(a.Pattern),
  type_: a.Type,
  bindings: Environment,
) -> Result(Environment, String) {
  case patterns {
    [] -> Ok(bindings)
    [p, ..rest] -> {
      use bindings <- c.then(pattern_bindings(p, type_, bindings))
      list_bindings(rest, type_, bindings)
    }
  }
}

fn list_element_type(
  elements: List(Typed),
  type_: a.Type,
) -> Result(a.Type, String) {
  case elements {
    [] -> Ok(type_)
    [e, ..rest] -> {
      use next <- c.then(merge_type(e.type_, type_))
      list_element_type(rest, next)
    }
  }
}

fn branch_type(arms: List(Arm), type_: a.Type) -> Result(a.Type, String) {
  case arms {
    [] -> Ok(type_)
    [arm, ..rest] -> {
      use next <- c.then(merge_type(arm.body.type_, type_))
      branch_type(rest, next)
    }
  }
}

// Preserve the legacy fast path and diagnostics. If it cannot prove a case,
// reuse the existing constructor-product matrix with one subject column.
fn case_exhaustive(
  arms: List(Arm),
  subject: Typed,
  globals: Globals,
) -> Result(Nil, String) {
  case
    exhaustive(
      arms,
      subject.type_,
      False,
      False,
      globals,
      subject.known_variant,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(legacy_error) ->
      case
        coverage.complete(
          c.map(arms, fn(arm) { [arm.pattern] }),
          [coverage.Column(subject.type_, subject.known_variant)],
          globals,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(legacy_error)
      }
  }
}

fn covers(p: a.Pattern, t: a.Type, globals: Globals) -> Bool {
  case a.without_alias(p), t {
    a.VariablePattern(_), _ | a.DiscardPattern, _ -> True
    a.CheckedBitArrayPattern([#(tail, a.BitsSegment)]), a.BitArrayType ->
      covers(tail, t, globals)
    a.TuplePattern(patterns), a.TupleType(types) ->
      tuple_covers(patterns, types, globals)
    a.ListPattern([], a.RestPattern(tail)), _ -> covers(tail, t, globals)
    a.CheckedConstructorPattern(_, fields), a.NamedType(name)
    | a.CheckedConstructorPattern(_, fields), a.AppliedType(name, _)
    ->
      case c.lookup(globals.custom_types, name) {
        Ok(a.CustomType(_, [_], _, _)) -> fields_cover(fields, globals)
        _ -> False
      }
    _, _ -> False
  }
}

fn covers_known(p: a.Pattern, t: a.Type, known: Int, globals: Globals) -> Bool {
  case a.without_alias(p) {
    a.CheckedConstructorPattern(tag, fields) if known != 0 && tag == known ->
      fields_cover(fields, globals)
    _ -> covers(p, t, globals)
  }
}

fn tuple_covers(
  patterns: List(a.Pattern),
  types: List(a.Type),
  globals: Globals,
) -> Bool {
  case patterns, types {
    [], [] -> True
    [p, ..patterns], [t, ..types] ->
      covers(p, t, globals) && tuple_covers(patterns, types, globals)
    _, _ -> False
  }
}

fn exhaustive(
  arms: List(Arm),
  t: a.Type,
  yes: Bool,
  no: Bool,
  globals: Globals,
  known: Int,
) -> Result(Nil, String) {
  case t {
    a.NamedType(name) | a.AppliedType(name, _) -> {
      use definition <- c.then(c.lookup(globals.custom_types, name))
      case
        any_cover(arms, t, globals)
        || case known {
          0 -> variants_cover(definition.variants, arms, globals)
          _ -> tag_cover(arms, known, globals)
        }
      {
        True -> Ok(Nil)
        False ->
          Error(
            "Non-exhaustive custom-type case: add missing variants or a catch-all",
          )
      }
    }
    _ -> exhaustive_primitive(arms, t, yes, no, globals)
  }
}

fn exhaustive_primitive(
  arms: List(Arm),
  t: a.Type,
  yes: Bool,
  no: Bool,
  globals: Globals,
) -> Result(Nil, String) {
  case arms {
    [] ->
      case yes && no {
        True -> Ok(Nil)
        False -> Error("Non-exhaustive case: add a catch-all pattern")
      }
    [arm, ..rest] ->
      case covers(arm.pattern, t, globals) {
        True -> Ok(Nil)
        False ->
          case a.without_alias(arm.pattern), t {
            a.BooleanPattern(True), a.Boolean ->
              exhaustive(rest, t, True, no, globals, 0)
            a.BooleanPattern(False), a.Boolean ->
              exhaustive(rest, t, yes, True, globals, 0)
            a.ListPattern([], a.NoPatternRest), a.ListType(_) ->
              exhaustive(rest, t, True, no, globals, 0)
            a.ListPattern([head], a.RestPattern(tail)), a.ListType(element) ->
              exhaustive(
                rest,
                t,
                yes,
                no
                  || {
                  covers(head, element, globals) && covers(tail, t, globals)
                },
                globals,
                0,
              )
            _, _ -> exhaustive(rest, t, yes, no, globals, 0)
          }
      }
  }
}

fn fields_cover(fields: List(#(a.Pattern, a.Type)), globals: Globals) -> Bool {
  case fields {
    [] -> True
    [#(p, t), ..rest] -> covers(p, t, globals) && fields_cover(rest, globals)
  }
}

fn any_cover(arms: List(Arm), t: a.Type, globals: Globals) -> Bool {
  case arms {
    [] -> False
    [arm, ..rest] ->
      covers(arm.pattern, t, globals) || any_cover(rest, t, globals)
  }
}

fn variants_cover(
  variants: List(a.Variant),
  arms: List(Arm),
  globals: Globals,
) -> Bool {
  case variants {
    [] -> True
    [variant, ..rest] ->
      case c.lookup(globals.constructors, variant.name) {
        Error(_) -> False
        Ok(definition) ->
          tag_cover(arms, definition.tag, globals)
          && variants_cover(rest, arms, globals)
      }
  }
}

fn tag_cover(arms: List(Arm), tag: Int, globals: Globals) -> Bool {
  case arms {
    [] -> False
    [arm, ..rest] ->
      case a.without_alias(arm.pattern) {
        a.CheckedConstructorPattern(id, fields) ->
          { id == tag && fields_cover(fields, globals) }
          || tag_cover(rest, tag, globals)
        _ -> tag_cover(rest, tag, globals)
      }
  }
}

// Update syntax is lowered to a scoped saved target and a new constructor.
// Retained fields constrain the new generic parameters; overwritten fields may
// change them, as upstream permits. The original object is never mutated.
type UpdateArgument {
  KeepField
  ReplaceField(a.Expression)
}

fn record_update(
  name: String,
  target: a.Expression,
  args: List(a.Argument),
  env: Environment,
  globals: Globals,
) -> Result(Typed, String) {
  use definition <- c.then(c.lookup(globals.constructors, name))
  use _ <- c.then(case definition.fields {
    [] -> Error("Invalid record update constructor: no fields")
    _ -> Ok(Nil)
  })
  use target <- c.then(expression(target, env, globals))
  use old_args <- c.then(constructor_type_arguments(definition, target.type_))
  use owner <- c.then(c.lookup(globals.custom_types, definition.owner))
  use _ <- c.then(
    case
      c.length(owner.variants) == 1 || target.known_variant == definition.tag
    {
      True -> Ok(Nil)
      False -> Error("Unsafe record update: target constructor is not known")
    },
  )
  use _ <- c.then(
    c.try_map(args, fn(arg) {
      case arg.label {
        "" -> Error("Record updates require labelled fields")
        _ -> Ok(Nil)
      }
    }),
  )
  use ordered <- c.then(labels.order(
    c.map(args, fn(arg) { #(arg.label, ReplaceField(arg.value)) }),
    definition.labels,
    labels.FillMissing(KeepField),
  ))
  use old_bindings <- c.then(types.bindings(definition.parameters, old_args))
  let saved =
    Typed(VariableNode("$record-update"), target.type_, definition.tag)
  use retained <- c.then(update_fields(
    ordered,
    definition.fields,
    old_bindings,
    saved,
    0,
    env,
    globals,
  ))
  // Every output parameter is fresh. Retained fields constrain it; parameters
  // absent from all fields remain free, including phantom parameters.
  let initial = c.map(definition.parameters, fn(n) { #(n, a.Unresolved) })
  use bindings <- c.then(infer_ready(retained, definition.fields, initial))
  use #(fields, bindings) <- c.then(finish_arguments(
    retained,
    bindings,
    env,
    globals,
  ))
  use params <- c.then(
    c.try_map(definition.parameters, fn(n) { c.lookup(bindings, n) }),
  )
  let result = types.apply(definition.owner, params)
  Ok(Typed(
    BlockNode([
      Bind(a.VariablePattern("$record-update"), target),
      Evaluate(Typed(
        ConstructorNode(definition.tag, fields),
        result,
        definition.tag,
      )),
    ]),
    result,
    definition.tag,
  ))
}

fn update_fields(
  args: List(UpdateArgument),
  formal: List(a.Type),
  old: types.Bindings,
  saved: Typed,
  index: Int,
  env: Environment,
  globals: Globals,
) -> Result(List(PreparedArgument), String) {
  case args, formal {
    [], [] -> Ok([])
    [arg, ..args], [t, ..formal] -> {
      use value <- c.then(case arg {
        ReplaceField(a.Lambda(_, _, _) as e) -> Ok(Pending(e, t))
        ReplaceField(e) -> {
          use typed <- c.then(expression(e, env, globals))
          Ok(Ready(typed))
        }
        KeepField -> {
          use field_type <- c.then(types.substitute(t, old))
          Ok(
            Ready(plain(
              FieldNode(saved, index, [saved.known_variant]),
              field_type,
            )),
          )
        }
      })
      use tail <- c.then(update_fields(
        args,
        formal,
        old,
        saved,
        index + 1,
        env,
        globals,
      ))
      Ok([value, ..tail])
    }
    _, _ -> Error("Record update field count mismatch")
  }
}

fn infer_ready(
  args: List(PreparedArgument),
  formal: List(a.Type),
  bindings: types.Bindings,
) -> Result(types.Bindings, String) {
  case args, formal {
    [], [] -> Ok(bindings)
    [arg, ..args], [t, ..formal] -> {
      use bindings <- c.then(case arg {
        Ready(value) -> types.infer(t, value.type_, bindings)
        Pending(_, _) -> Ok(bindings)
      })
      infer_ready(args, formal, bindings)
    }
    _, _ -> Error("Record update field count mismatch")
  }
}

fn bit_segment_type(mode: a.BitMode) -> a.Type {
  case mode {
    a.IntegerSegment(_, _, _) -> a.Integer
    a.BitsSegment | a.BytesSegment -> a.BitArrayType
    a.Utf8Segment -> a.StringType
  }
}

fn bit_patterns(
  segments: List(a.BitSegment(a.Pattern)),
  globals: Globals,
) -> Result(List(#(a.Pattern, a.BitMode)), String) {
  case segments {
    [] -> Ok([])
    [segment, ..rest] -> {
      use mode <- c.then(bit_options.mode(segment.options, True))
      use _ <- c.then(case mode {
        a.BitsSegment | a.BytesSegment ->
          case rest, segment.value {
            [], a.VariablePattern(_) | [], a.DiscardPattern -> Ok(Nil)
            _, _ ->
              Error(
                "Unsized bit-array pattern tail must be last and bind a variable or discard",
              )
          }
        _ ->
          case segment.value {
            a.IntegerPattern(_) | a.VariablePattern(_) | a.DiscardPattern ->
              Ok(Nil)
            _ ->
              Error(
                "Integer bit-array segment pattern requires an integer, variable or discard",
              )
          }
      })
      use p <- c.then(resolve_pattern(
        segment.value,
        bit_segment_type(mode),
        globals,
      ))
      use tail <- c.then(bit_patterns(rest, globals))
      Ok([#(p, mode), ..tail])
    }
  }
}

// Guard expressions are a restricted pure language, not arbitrary expressions.
// In particular, validating normal function bodies does not make calls legal.
fn guard_source(e: a.Expression) -> Result(Nil, String) {
  case e {
    a.IntegerLiteral(_)
    | a.BooleanLiteral(_)
    | a.UnitLiteral
    | a.StringLiteral(_)
    | a.Variable(_) -> Ok(Nil)
    a.Unary(_, e)
    | a.TupleIndex(e, _)
    | a.FieldAccess(e, _)
    | a.ModuleFallbackField(e, _, _) -> guard_source(e)
    a.Binary(_, l, r) -> {
      use _ <- c.then(guard_source(l))
      guard_source(r)
    }
    a.Block([a.Evaluate(e)]) -> guard_source(e)
    _ ->
      Error(
        "Unsupported guard expression: calls/bindings/effects forbidden; construction not implemented",
      )
  }
}

fn unguarded(arms: List(Arm)) -> List(Arm) {
  case arms {
    [] -> []
    [arm, ..rest] ->
      case arm.guard {
        a.NoGuard -> [arm, ..unguarded(rest)]
        a.Guard(_) -> unguarded(rest)
      }
  }
}

fn multi_case(
  subjects: List(a.Expression),
  arms: List(a.MultiArm),
  env: Environment,
  globals: Globals,
  expected: a.Type,
) -> Result(Typed, String) {
  use subjects <- c.then(
    c.try_map(subjects, fn(e) { expression(e, env, globals) }),
  )
  use _ <- c.then(case subjects {
    [] -> Error("Empty case subject list")
    _ -> Ok(Nil)
  })
  use typed <- c.then(
    c.try_map(arms, fn(arm) {
      use rows <- c.then(
        c.try_map(arm.alternatives, fn(row) {
          check_row(row, subjects, globals)
        }),
      )
      use bindings <- c.then(common_bindings(rows))
      let branch_env = c.append(bindings, env)
      use body <- c.then(expression_expected(
        arm.body,
        branch_env,
        globals,
        expected,
      ))
      use guard <- c.then(case arm.guard {
        a.NoGuard -> Ok(a.NoGuard)
        a.Guard(e) -> {
          use _ <- c.then(guard_source(e))
          use value <- c.then(expression(e, branch_env, globals))
          use _ <- c.then(equal(value.type_, a.Boolean))
          Ok(a.Guard(value))
        }
      })
      Ok(MultiArm(
        c.map(rows, fn(r) { r.0 }),
        c.map(bindings, fn(b) { b.0 }),
        guard,
        body,
      ))
    }),
  )
  use _ <- c.then(coverage.complete(
    coverage_rows(typed),
    c.map(subjects, fn(s) { coverage.Column(s.type_, s.known_variant) }),
    globals,
  ))
  case typed {
    [] -> Error("Empty case")
    [first, ..rest] -> {
      use result <- c.then(multi_branch_type(rest, first.body.type_))
      Ok(plain(MultiCaseNode(subjects, typed), result))
    }
  }
}

fn check_row(
  patterns: List(a.Pattern),
  subjects: List(Typed),
  globals: Globals,
) -> Result(#(List(a.Pattern), Environment), String) {
  use _ <- c.then(case c.length(patterns) == c.length(subjects) {
    True -> Ok(Nil)
    False -> Error("Case pattern count does not match subject count")
  })
  use fields <- c.then(resolve_fields(
    patterns,
    c.map(subjects, fn(s) { s.type_ }),
    globals,
  ))
  use bindings <- c.then(checked_field_bindings(fields, []))
  let patterns = c.map(fields, fn(f) { f.0 })
  let bindings = row_known(patterns, subjects, bindings)
  Ok(#(patterns, bindings))
}

fn row_known(
  patterns: List(a.Pattern),
  subjects: List(Typed),
  bindings: Environment,
) -> Environment {
  case patterns, subjects {
    [], [] -> bindings
    [p, ..ps], [subject, ..ss] ->
      row_known(
        ps,
        ss,
        known_bindings(p, subject.type_, subject.known_variant, bindings),
      )
    _, _ -> bindings
  }
}

fn common_bindings(
  rows: List(#(List(a.Pattern), Environment)),
) -> Result(Environment, String) {
  case rows {
    [] -> Error("Empty alternative list")
    [first, ..rest] -> merge_environments(rest, first.1)
  }
}

fn merge_environments(
  rows: List(#(List(a.Pattern), Environment)),
  current: Environment,
) -> Result(Environment, String) {
  case rows {
    [] -> Ok(current)
    [row, ..rest] -> {
      use _ <- c.then(case c.length(current) == c.length(row.1) {
        True -> Ok(Nil)
        False -> Error("Alternative patterns must bind the same variables")
      })
      use merged <- c.then(
        c.try_map(current, fn(entry) {
          use other <- c.then(case c.lookup(row.1, entry.0) {
            Ok(other) -> Ok(other)
            Error(_) ->
              Error(
                "Alternative patterns must bind the same variables: " <> entry.0,
              )
          })
          use t <- c.then(merge_type(entry.1.type_, other.type_))
          let known = case entry.1.known_variant == other.known_variant {
            True -> entry.1.known_variant
            False -> 0
          }
          Ok(#(entry.0, Local(t, known, entry.1.read)))
        }),
      )
      merge_environments(rest, merged)
    }
  }
}

fn coverage_rows(arms: List(MultiArm)) -> List(List(a.Pattern)) {
  case arms {
    [] -> []
    [arm, ..rest] ->
      case arm.guard {
        a.NoGuard -> c.append(arm.alternatives, coverage_rows(rest))
        a.Guard(_) -> coverage_rows(rest)
      }
  }
}

fn multi_branch_type(
  arms: List(MultiArm),
  current: a.Type,
) -> Result(a.Type, String) {
  case arms {
    [] -> Ok(current)
    [arm, ..rest] -> {
      use current <- c.then(merge_type(current, arm.body.type_))
      multi_branch_type(rest, current)
    }
  }
}
