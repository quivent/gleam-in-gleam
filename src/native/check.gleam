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
  VariableNode(String)
  UnaryNode(String, Typed)
  BinaryNode(String, Typed, Typed)
  CallNode(String, List(Typed))
  BlockNode(List(Statement))
  CaseNode(Typed, List(Arm))
  EchoNode(Typed)
}

pub type Statement {
  Bind(String, Typed)
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
  case actual == expected {
    True -> Ok(Nil)
    False ->
      Error(
        "Type mismatch: expected "
        <> type_name(expected)
        <> ", found "
        <> type_name(actual),
      )
  }
}

pub fn type_name(t: a.Type) -> String {
  case t {
    a.Integer -> "Int"
    a.Boolean -> "Bool"
    a.Unit -> "Nil"
    a.StringType -> "String"
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
    [a.Bind(name, annotation, value), ..rest] -> {
      use typed <- c.then(expression(value, env, globals))
      use _ <- c.then(case annotation {
        a.Inferred -> Ok(Nil)
        a.Annotated(t) -> equal(typed.type_, t)
      })
      case rest {
        [] ->
          Error("A function/block must end in an expression, not an assignment")
        _ -> {
          use #(tail, t) <- c.then(statements(
            rest,
            [#(name, typed.type_), ..env],
            globals,
          ))
          Ok(#([Bind(name, typed), ..tail], t))
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
      Ok(Typed(EchoNode(typed), typed.type_))
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
          use _ <- c.then(
            c.try_map(rest, fn(arm) { equal(arm.body.type_, first.body.type_) }),
          )
          Ok(Typed(CaseNode(subject, arms), first.body.type_))
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
  case p {
    a.DiscardPattern -> Ok(env)
    a.VariablePattern(name) -> Ok([#(name, t), ..env])
    a.IntegerPattern(_) -> {
      use _ <- c.then(equal(t, a.Integer))
      Ok(env)
    }
    a.BooleanPattern(_) -> {
      use _ <- c.then(equal(t, a.Boolean))
      Ok(env)
    }
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
      case t == a.Boolean && yes && no {
        True -> Ok(Nil)
        False -> Error("Non-exhaustive case: add a catch-all pattern")
      }
    [a.Arm(a.DiscardPattern, _), ..] | [a.Arm(a.VariablePattern(_), _), ..] ->
      Ok(Nil)
    [a.Arm(a.BooleanPattern(True), _), ..rest] -> exhaustive(rest, t, True, no)
    [a.Arm(a.BooleanPattern(False), _), ..rest] ->
      exhaustive(rest, t, yes, True)
    [_, ..rest] -> exhaustive(rest, t, yes, no)
  }
}
