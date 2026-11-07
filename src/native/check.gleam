import native/ast as a
import native/core as c

pub type Typed {
  Typed(node: Node, type_: a.Type)
}

pub type Node {
  IntegerNode(Int)
  BooleanNode(Bool)
  UnitNode
  StringNode(BitArray)
  TupleNode(List(Typed))
  ListNode(List(Typed), Tail)
  TupleIndexNode(Typed, Int)
  VariableNode(String)
  UnaryNode(String, Typed)
  BinaryNode(String, Typed, Typed)
  CallNode(String, List(Typed))
  BlockNode(List(Statement))
  CaseNode(Typed, List(Arm))
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

pub type Arm {
  Arm(pattern: a.Pattern, body: Typed)
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
  List(#(String, a.Type))

type Globals =
  List(#(String, a.Function))

fn equal(actual: a.Type, expected: a.Type) -> Result(Nil, String) {
  case merge_type(actual, expected) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(e)
  }
}

fn merge_type(actual: a.Type, expected: a.Type) -> Result(a.Type, String) {
  case actual, expected {
    a.Unresolved, t | t, a.Unresolved -> Ok(t)
    a.ListType(left), a.ListType(right) -> {
      use t <- c.then(merge_type(left, right))
      Ok(a.ListType(t))
    }
    a.TupleType(left), a.TupleType(right) -> {
      use types <- c.then(merge_types(left, right))
      Ok(a.TupleType(types))
    }
    _, _ ->
      case actual == expected {
        True -> Ok(actual)
        False ->
          Error(
            "Type mismatch: expected "
            <> type_name(expected)
            <> ", found "
            <> type_name(actual),
          )
      }
  }
}

fn merge_types(
  left: List(a.Type),
  right: List(a.Type),
) -> Result(List(a.Type), String) {
  case left, right {
    [], [] -> Ok([])
    [l, ..left], [r, ..right] -> {
      use t <- c.then(merge_type(l, r))
      use tail <- c.then(merge_types(left, right))
      Ok([t, ..tail])
    }
    _, _ -> Error("Tuple arity mismatch")
  }
}

pub fn type_name(t: a.Type) -> String {
  case t {
    a.Integer -> "Int"
    a.Boolean -> "Bool"
    a.Unit -> "Nil"
    a.StringType -> "String"
    a.TupleType(types) -> "#(" <> c.join(c.map(types, type_name), ", ") <> ")"
    a.ListType(element) -> "List(" <> type_name(element) <> ")"
    a.Unresolved -> "unresolved empty-list element"
  }
}

pub fn module(module: a.Module) -> Result(List(Function), String) {
  use globals <- c.then(signatures(module.functions, []))
  use main <- c.then(c.lookup(globals, "main"))
  case main.parameters {
    [] -> c.try_map(module.functions, fn(f) { function(f, globals) })
    _ -> Error("main must have no parameters")
  }
}

fn signatures(
  functions: List(a.Function),
  acc: Globals,
) -> Result(Globals, String) {
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
  parameters: Environment,
  seen: Environment,
) -> Result(Nil, String) {
  case parameters {
    [] -> Ok(Nil)
    [#("_", _), ..rest] -> unique_parameters(rest, seen)
    [#(name, t), ..rest] ->
      case c.lookup(seen, name) {
        Ok(_) -> Error("Duplicate parameter: " <> name)
        Error(_) -> unique_parameters(rest, [#(name, t), ..seen])
      }
  }
}

fn function(f: a.Function, globals: Globals) -> Result(Function, String) {
  use #(body, result_type) <- c.then(statements(f.body, f.parameters, globals))
  use _ <- c.then(equal(result_type, f.result))
  Ok(Function(f.name, f.parameters, f.result, body))
}

fn statements(
  xs: List(a.Statement),
  env: Environment,
  globals: Globals,
) -> Result(#(List(Statement), a.Type), String) {
  case xs {
    [] -> Ok(#([], a.Unit))
    [a.Bind(pat, annotation, value), ..rest] -> {
      use typed <- c.then(expression(value, env, globals))
      use typed <- c.then(case annotation {
        a.Inferred -> Ok(typed)
        a.Annotated(t) -> {
          use _ <- c.then(equal(typed.type_, t))
          Ok(Typed(..typed, type_: t))
        }
      })
      use _ <- c.then(case covers(pat, typed.type_) {
        True -> Ok(Nil)
        False ->
          Error(
            "Refutable let pattern: use case (let assert is not implemented)",
          )
      })
      use next_env <- c.then(pattern(pat, typed.type_, env))
      case rest {
        [] ->
          Error("A function/block must end in an expression, not an assignment")
        _ -> {
          use #(tail, t) <- c.then(statements(rest, next_env, globals))
          Ok(#([Bind(pat, typed), ..tail], t))
        }
      }
    }
    [a.Evaluate(value), ..rest] -> {
      use typed <- c.then(expression(value, env, globals))
      case rest {
        [] -> Ok(#([Evaluate(typed)], typed.type_))
        _ -> {
          use #(tail, t) <- c.then(statements(rest, env, globals))
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
    a.IntegerLiteral(n) -> Ok(Typed(IntegerNode(n), a.Integer))
    a.BooleanLiteral(b) -> Ok(Typed(BooleanNode(b), a.Boolean))
    a.UnitLiteral -> Ok(Typed(UnitNode, a.Unit))
    a.StringLiteral(s) -> Ok(Typed(StringNode(s), a.StringType))
    a.TupleLiteral(elements) -> {
      use typed <- c.then(
        c.try_map(elements, fn(e) { expression(e, env, globals) }),
      )
      Ok(Typed(TupleNode(typed), a.TupleType(c.map(typed, fn(e) { e.type_ }))))
    }
    a.TupleIndex(tuple, index) -> {
      use tuple <- c.then(expression(tuple, env, globals))
      case tuple.type_ {
        a.TupleType(elements) -> {
          use type_ <- c.then(c.nth(elements, index))
          Ok(Typed(TupleIndexNode(tuple, index), type_))
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
      Ok(Typed(ListNode(elements, tail), a.ListType(element)))
    }
    a.Variable("_") -> Error("Discarded variable cannot be read")
    a.Variable(name) -> {
      use t <- c.then(c.lookup(env, name))
      Ok(Typed(VariableNode(name), t))
    }
    a.Unary(op, inner) -> {
      use typed <- c.then(expression(inner, env, globals))
      let t = case op {
        "-" -> a.Integer
        _ -> a.Boolean
      }
      use _ <- c.then(equal(typed.type_, t))
      Ok(Typed(UnaryNode(op, typed), t))
    }
    a.Binary(op, left, right) -> {
      use left <- c.then(expression(left, env, globals))
      use right <- c.then(expression(right, env, globals))
      use result <- c.then(binary_type(op, left.type_, right.type_))
      Ok(Typed(BinaryNode(op, left, right), result))
    }
    a.Call(name, args) -> {
      use f <- c.then(c.lookup(globals, name))
      use args <- c.then(c.try_map(args, fn(e) { expression(e, env, globals) }))
      use _ <- c.then(arguments(args, f.parameters))
      Ok(Typed(CallNode(name, args), f.result))
    }
    a.Block(body) -> {
      use #(body, t) <- c.then(statements(body, env, globals))
      Ok(Typed(BlockNode(body), t))
    }
    a.Echo(inner) -> {
      use typed <- c.then(expression(inner, env, globals))
      case typed.type_ {
        a.TupleType(_) | a.ListType(_) | a.Unresolved ->
          Error("Compound-value echo formatting is not implemented yet")
        _ -> Ok(Typed(EchoNode(typed), typed.type_))
      }
    }
    a.Case(subject, arms) -> {
      use subject <- c.then(expression(subject, env, globals))
      use _ <- c.then(exhaustive(arms, subject.type_, False, False))
      use arms <- c.then(
        c.try_map(arms, fn(arm) {
          use branch_env <- c.then(pattern(arm.pattern, subject.type_, env))
          use body <- c.then(expression(arm.body, branch_env, globals))
          Ok(Arm(arm.pattern, body))
        }),
      )
      case arms {
        [] -> Error("Empty case")
        [first, ..rest] -> {
          use result <- c.then(branch_type(rest, first.body.type_))
          Ok(Typed(CaseNode(subject, arms), result))
        }
      }
    }
  }
}

fn binary_type(
  op: String,
  left: a.Type,
  right: a.Type,
) -> Result(a.Type, String) {
  case op {
    "&&" | "||" -> {
      use _ <- c.then(equal(left, a.Boolean))
      use _ <- c.then(equal(right, a.Boolean))
      Ok(a.Boolean)
    }
    "==" | "!=" -> {
      use _ <- c.then(equal(left, right))
      case left {
        a.StringType ->
          Error("Structural String equality is not implemented yet")
        a.ListType(_) | a.TupleType(_) | a.Unresolved ->
          Error("Structural compound equality is not implemented yet")
        _ -> Ok(a.Boolean)
      }
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

fn arguments(args: List(Typed), params: Environment) -> Result(Nil, String) {
  case args, params {
    [], [] -> Ok(Nil)
    [a, ..args], [#(_, t), ..params] -> {
      use _ <- c.then(equal(a.type_, t))
      arguments(args, params)
    }
    _, _ -> Error("Function argument count mismatch")
  }
}

fn pattern(
  p: a.Pattern,
  t: a.Type,
  env: Environment,
) -> Result(Environment, String) {
  use bindings <- c.then(pattern_bindings(p, t, []))
  Ok(c.append(bindings, env))
}

fn pattern_bindings(
  p: a.Pattern,
  t: a.Type,
  bindings: Environment,
) -> Result(Environment, String) {
  case p {
    a.DiscardPattern -> Ok(bindings)
    a.VariablePattern(name) ->
      case c.lookup(bindings, name) {
        Ok(_) -> Error("Duplicate variable in pattern: " <> name)
        Error(_) -> Ok([#(name, t), ..bindings])
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

fn covers(p: a.Pattern, t: a.Type) -> Bool {
  case p, t {
    a.VariablePattern(_), _ | a.DiscardPattern, _ -> True
    a.TuplePattern(patterns), a.TupleType(types) ->
      tuple_covers(patterns, types)
    a.ListPattern([], a.RestPattern(tail)), _ -> covers(tail, t)
    _, _ -> False
  }
}

fn tuple_covers(patterns: List(a.Pattern), types: List(a.Type)) -> Bool {
  case patterns, types {
    [], [] -> True
    [p, ..patterns], [t, ..types] ->
      covers(p, t) && tuple_covers(patterns, types)
    _, _ -> False
  }
}

fn exhaustive(
  arms: List(a.Arm),
  t: a.Type,
  yes: Bool,
  no: Bool,
) -> Result(Nil, String) {
  case arms {
    [] ->
      case yes && no {
        True -> Ok(Nil)
        False -> Error("Non-exhaustive case: add a catch-all pattern")
      }
    [arm, ..rest] ->
      case covers(arm.pattern, t) {
        True -> Ok(Nil)
        False ->
          case arm.pattern, t {
            a.BooleanPattern(True), a.Boolean -> exhaustive(rest, t, True, no)
            a.BooleanPattern(False), a.Boolean -> exhaustive(rest, t, yes, True)
            a.ListPattern([], a.NoPatternRest), a.ListType(_) ->
              exhaustive(rest, t, True, no)
            a.ListPattern([head], a.RestPattern(tail)), a.ListType(element) ->
              exhaustive(
                rest,
                t,
                yes,
                no || { covers(head, element) && covers(tail, t) },
              )
            _, _ -> exhaustive(rest, t, yes, no)
          }
      }
  }
}
