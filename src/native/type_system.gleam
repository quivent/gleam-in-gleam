// Type algebra only. These substitutions never generate native runtime work.
import native/ast as a
import native/core as c

pub type Bindings =
  List(#(String, a.Type))

pub fn name(t: a.Type) -> String {
  case t {
    a.Integer -> "Int"
    a.Boolean -> "Bool"
    a.Unit -> "Nil"
    a.StringType -> "String"
    a.NamedType(n) | a.VariableType(n) -> n
    a.AppliedType(n, args) -> n <> "(" <> c.join(c.map(args, name), ", ") <> ")"
    a.ListType(t) -> "List(" <> name(t) <> ")"
    a.TupleType(types) -> "#(" <> c.join(c.map(types, name), ", ") <> ")"
    a.FunctionType(params, result) ->
      "fn(" <> c.join(c.map(params, name), ", ") <> ") -> " <> name(result)
    a.Unresolved -> "unresolved type"
  }
}

pub fn merge(actual: a.Type, expected: a.Type) -> Result(a.Type, String) {
  case actual, expected {
    a.Unresolved, t | t, a.Unresolved -> Ok(t)
    a.ListType(l), a.ListType(r) -> {
      use t <- c.then(merge(l, r))
      Ok(a.ListType(t))
    }
    a.TupleType(l), a.TupleType(r) -> {
      use types <- c.then(merge_many(l, r))
      Ok(a.TupleType(types))
    }
    a.FunctionType(l, lr), a.FunctionType(r, rr) -> {
      use params <- c.then(merge_many(l, r))
      use result <- c.then(merge(lr, rr))
      Ok(a.FunctionType(params, result))
    }
    a.AppliedType(n, l), a.AppliedType(m, r) if n == m -> {
      use types <- c.then(merge_many(l, r))
      Ok(a.AppliedType(n, types))
    }
    _, _ ->
      case actual == expected {
        True -> Ok(actual)
        False ->
          Error(
            "Type mismatch: expected "
            <> name(expected)
            <> ", found "
            <> name(actual),
          )
      }
  }
}

fn merge_many(
  l: List(a.Type),
  r: List(a.Type),
) -> Result(List(a.Type), String) {
  case l, r {
    [], [] -> Ok([])
    [x, ..l], [y, ..r] -> {
      use t <- c.then(merge(x, y))
      use tail <- c.then(merge_many(l, r))
      Ok([t, ..tail])
    }
    _, _ -> Error("Tuple/type argument arity mismatch")
  }
}

pub fn infer(
  formal: a.Type,
  actual: a.Type,
  bindings: Bindings,
) -> Result(Bindings, String) {
  case formal, actual {
    a.VariableType(n), t -> {
      case c.lookup(bindings, n) {
        Ok(old) -> {
          use t <- c.then(merge(old, t))
          Ok(c.put(bindings, n, t))
        }
        Error(_) -> {
          use _ <- c.then(merge(formal, actual))
          Ok(bindings)
        }
      }
    }
    _, a.Unresolved -> Ok(bindings)
    a.ListType(l), a.ListType(r) -> infer(l, r, bindings)
    a.TupleType(l), a.TupleType(r) -> infer_many(l, r, bindings)
    a.FunctionType(l, lr), a.FunctionType(r, rr) -> {
      use bindings <- c.then(infer_many(l, r, bindings))
      infer(lr, rr, bindings)
    }
    a.AppliedType(n, l), a.AppliedType(m, r) if n == m ->
      infer_many(l, r, bindings)
    _, _ -> {
      use _ <- c.then(merge(formal, actual))
      Ok(bindings)
    }
  }
}

pub fn infer_many(
  formal: List(a.Type),
  actual: List(a.Type),
  bindings: Bindings,
) -> Result(Bindings, String) {
  case formal, actual {
    [], [] -> Ok(bindings)
    [f, ..formal], [t, ..actual] -> {
      use bindings <- c.then(infer(f, t, bindings))
      infer_many(formal, actual, bindings)
    }
    _, _ -> Error("Constructor/type argument count mismatch")
  }
}

pub fn substitute(t: a.Type, bindings: Bindings) -> Result(a.Type, String) {
  case t {
    a.VariableType(n) ->
      case c.lookup(bindings, n) {
        Ok(t) -> Ok(t)
        Error(_) -> Ok(t)
      }
    a.ListType(t) -> {
      use t <- c.then(substitute(t, bindings))
      Ok(a.ListType(t))
    }
    a.TupleType(types) -> {
      use types <- c.then(c.try_map(types, fn(t) { substitute(t, bindings) }))
      Ok(a.TupleType(types))
    }
    a.FunctionType(params, result) -> {
      use params <- c.then(c.try_map(params, fn(t) { substitute(t, bindings) }))
      use result <- c.then(substitute(result, bindings))
      Ok(a.FunctionType(params, result))
    }
    a.AppliedType(n, types) -> {
      use types <- c.then(c.try_map(types, fn(t) { substitute(t, bindings) }))
      Ok(a.AppliedType(n, types))
    }
    _ -> Ok(t)
  }
}

pub fn apply(n: String, args: List(a.Type)) -> a.Type {
  case args {
    [] -> a.NamedType(n)
    _ -> a.AppliedType(n, args)
  }
}

pub fn variables(types: List(a.Type)) -> List(String) {
  c.reverse(collect_variables(types, []))
}

fn collect_variables(types: List(a.Type), seen: List(String)) -> List(String) {
  case types {
    [] -> seen
    [t, ..rest] -> {
      let seen = case t {
        a.VariableType(n) ->
          case c.lookup(c.map(seen, fn(s) { #(s, Nil) }), n) {
            Ok(_) -> seen
            Error(_) -> [n, ..seen]
          }
        a.ListType(t) -> collect_variables([t], seen)
        a.TupleType(ts) | a.AppliedType(_, ts) -> collect_variables(ts, seen)
        a.FunctionType(params, result) ->
          collect_variables(c.append(params, [result]), seen)
        _ -> seen
      }
      collect_variables(rest, seen)
    }
  }
}

pub fn bindings(
  params: List(String),
  args: List(a.Type),
) -> Result(Bindings, String) {
  case params, args {
    [], [] -> Ok([])
    [n, ..params], [t, ..args] -> {
      use rest <- c.then(bindings(params, args))
      Ok([#(n, t), ..rest])
    }
    _, _ -> Error("Type argument count mismatch")
  }
}
