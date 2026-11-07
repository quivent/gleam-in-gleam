import native/ast as a
import native/core as c
import native/definitions as d
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
  ListNode(List(Typed), Tail)
  TupleIndexNode(Typed, Int)
  ConstructorNode(Int, List(Typed))
  FieldNode(Typed, Int, List(Int))
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
  List(#(String, Local))

type Local {
  Local(type_: a.Type, known_variant: Int)
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
  use _ <- c.then(signatures(module.functions, []))
  use globals <- c.then(d.collect(module))
  use main <- c.then(c.lookup(globals.functions, "main"))
  case main.parameters {
    [] -> c.try_map(module.functions, fn(f) { function(f, globals) })
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
    [#("_", _), ..rest] -> unique_parameters(rest, seen)
    [#(name, t), ..rest] ->
      case c.lookup(seen, name) {
        Ok(_) -> Error("Duplicate parameter: " <> name)
        Error(_) -> unique_parameters(rest, [#(name, t), ..seen])
      }
  }
}

fn function(f: a.Function, globals: Globals) -> Result(Function, String) {
  use #(body, result_type) <- c.then(statements(
    f.body,
    c.map(f.parameters, fn(p) { #(p.0, Local(p.1, 0)) }),
    globals,
  ))
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
    a.IntegerLiteral(n) -> Ok(plain(IntegerNode(n), a.Integer))
    a.BooleanLiteral(b) -> Ok(plain(BooleanNode(b), a.Boolean))
    a.UnitLiteral -> Ok(plain(UnitNode, a.Unit))
    a.StringLiteral(s) -> Ok(plain(StringNode(s), a.StringType))
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
    a.Variable("_") -> Error("Discarded variable cannot be read")
    a.Variable(name) -> {
      case c.uppercase_name(name) {
        True -> constructor(name, [], env, globals, False)
        False -> {
          use local <- c.then(c.lookup(env, name))
          Ok(Typed(VariableNode(name), local.type_, local.known_variant))
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
      use result <- c.then(binary_type(op, left.type_, right.type_))
      Ok(plain(BinaryNode(op, left, right), result))
    }
    a.Call(name, args) -> {
      case c.uppercase_name(name) {
        True -> constructor(name, args, env, globals, True)
        False -> {
          use args <- c.then(
            c.try_map(args, fn(arg) {
              case arg.label {
                "" -> expression(arg.value, env, globals)
                _ -> Error("Labelled function calls are not implemented yet")
              }
            }),
          )
          use f <- c.then(c.lookup(globals.functions, name))
          use _ <- c.then(arguments(args, f.parameters))
          Ok(plain(CallNode(name, args), f.result))
        }
      }
    }
    a.FieldAccess(target, field) -> {
      use target <- c.then(expression(target, env, globals))
      field_access(target, field, globals)
    }
    a.Block(body) -> {
      use #(body, t) <- c.then(statements(body, env, globals))
      Ok(plain(BlockNode(body), t))
    }
    a.Echo(inner) -> {
      use typed <- c.then(expression(inner, env, globals))
      case typed.type_ {
        a.TupleType(_)
        | a.ListType(_)
        | a.NamedType(_)
        | a.AppliedType(_, _)
        | a.VariableType(_)
        | a.Unresolved ->
          Error("Compound-value echo formatting is not implemented yet")
        _ -> Ok(plain(EchoNode(typed), typed.type_))
      }
    }
    a.Case(subject, arms) -> {
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
          use body <- c.then(expression(arm.body, branch_env, globals))
          Ok(Arm(pat, body))
        }),
      )
      use _ <- c.then(exhaustive(
        arms,
        subject.type_,
        False,
        False,
        globals,
        subject.known_variant,
      ))
      case arms {
        [] -> Error("Empty case")
        [first, ..rest] -> {
          use result <- c.then(branch_type(rest, first.body.type_))
          Ok(plain(CaseNode(subject, arms), result))
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
        a.ListType(_)
        | a.TupleType(_)
        | a.NamedType(_)
        | a.AppliedType(_, _)
        | a.VariableType(_)
        | a.Unresolved ->
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

fn arguments(
  args: List(Typed),
  params: List(#(String, a.Type)),
) -> Result(Nil, String) {
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
  globals: Globals,
  known: Int,
) -> Result(#(a.Pattern, Environment), String) {
  use resolved <- c.then(resolve_pattern(p, t, globals))
  use bindings <- c.then(pattern_bindings(resolved, t, []))
  case resolved {
    a.VariablePattern(name) ->
      Ok(#(resolved, [#(name, Local(t, known)), ..env]))
    _ -> Ok(#(resolved, c.append(bindings, env)))
  }
}

fn constructor(
  name: String,
  args: List(a.Argument),
  env: Environment,
  globals: Globals,
  called: Bool,
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
  use args <- c.then(
    c.try_map(ordered, fn(arg) { expression(arg, env, globals) }),
  )
  let initial = c.map(definition.parameters, fn(n) { #(n, a.Unresolved) })
  use bindings <- c.then(types.infer_many(
    definition.fields,
    c.map(args, fn(arg) { arg.type_ }),
    initial,
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
    a.ConstructorPattern(_, _, _) -> Error("Unresolved constructor pattern")
    a.CheckedConstructorPattern(_, fields) ->
      checked_field_bindings(fields, bindings)
    a.DiscardPattern -> Ok(bindings)
    a.VariablePattern(name) ->
      case c.lookup(bindings, name) {
        Ok(_) -> Error("Duplicate variable in pattern: " <> name)
        Error(_) -> Ok([#(name, Local(t, 0)), ..bindings])
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

fn covers(p: a.Pattern, t: a.Type, globals: Globals) -> Bool {
  case p, t {
    a.VariablePattern(_), _ | a.DiscardPattern, _ -> True
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
  case p {
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
          case arm.pattern, t {
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
    [Arm(a.CheckedConstructorPattern(id, fields), _), ..rest] ->
      { id == tag && fields_cover(fields, globals) }
      || tag_cover(rest, tag, globals)
    [_, ..rest] -> tag_cover(rest, tag, globals)
  }
}
