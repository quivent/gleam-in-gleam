// Lexical free-variable analysis over source AST. Global names are filtered by
// the checker against the actual surrounding local environment.
import native/ast as a
import native/core as c

pub fn pattern_names(p: a.Pattern) -> List(String) {
  case p {
    a.VariablePattern(n) -> [n]
    a.TuplePattern(ps) -> patterns(ps)
    a.ListPattern(ps, tail) ->
      c.append(patterns(ps), case tail {
        a.NoPatternRest -> []
        a.RestPattern(p) -> pattern_names(p)
      })
    a.ConstructorPattern(_, fields, _) ->
      patterns(c.map(fields, fn(f) { f.pattern }))
    a.CheckedConstructorPattern(_, fields) ->
      patterns(c.map(fields, fn(f) { f.0 }))
    _ -> []
  }
}

fn patterns(ps: List(a.Pattern)) -> List(String) {
  case ps {
    [] -> []
    [p, ..rest] -> c.append(pattern_names(p), patterns(rest))
  }
}

pub fn names(body: List(a.Statement), bound: List(String)) -> List(String) {
  c.reverse(statements(body, bound, []))
}

fn add(name: String, bound: List(String), free: List(String)) -> List(String) {
  case c.lookup(c.map(c.append(bound, free), fn(n) { #(n, Nil) }), name) {
    Ok(_) -> free
    Error(_) -> [name, ..free]
  }
}

fn statements(
  body: List(a.Statement),
  bound: List(String),
  free: List(String),
) -> List(String) {
  case body {
    [] -> free
    [a.Evaluate(e), ..rest] ->
      statements(rest, bound, expression(e, bound, free))
    [a.Bind(p, _, e), ..rest] -> {
      let free = expression(e, bound, free)
      statements(rest, c.append(pattern_names(p), bound), free)
    }
  }
}

fn expressions(
  values: List(a.Expression),
  bound: List(String),
  free: List(String),
) -> List(String) {
  case values {
    [] -> free
    [e, ..rest] -> expressions(rest, bound, expression(e, bound, free))
  }
}

fn expression(
  e: a.Expression,
  bound: List(String),
  free: List(String),
) -> List(String) {
  case e {
    a.Variable(n) -> add(n, bound, free)
    a.Unary(_, e) | a.Echo(e) | a.TupleIndex(e, _) | a.FieldAccess(e, _) ->
      expression(e, bound, free)
    a.Binary(_, l, r) -> expressions([l, r], bound, free)
    a.TupleLiteral(es) -> expressions(es, bound, free)
    a.ListLiteral(es, tail) -> {
      let free = expressions(es, bound, free)
      case tail {
        a.NoRest -> free
        a.Rest(e) -> expression(e, bound, free)
      }
    }
    a.Call(n, args) ->
      expressions(
        c.map(args, fn(arg) { arg.value }),
        bound,
        add(n, bound, free),
      )
    a.Apply(target, args) ->
      expressions([target, ..c.map(args, fn(arg) { arg.value })], bound, free)
    a.Block(body) -> statements(body, bound, free)
    a.Lambda(params, _, body) -> {
      let names = patterns(c.map(params, fn(p) { p.pattern }))
      statements(body, c.append(names, bound), free)
    }
    a.Case(subject, arms) ->
      case_arms(arms, bound, expression(subject, bound, free))
    _ -> free
  }
}

fn case_arms(
  arms: List(a.Arm),
  bound: List(String),
  free: List(String),
) -> List(String) {
  case arms {
    [] -> free
    [arm, ..rest] ->
      case_arms(
        rest,
        bound,
        expression(arm.body, c.append(pattern_names(arm.pattern), bound), free),
      )
  }
}
