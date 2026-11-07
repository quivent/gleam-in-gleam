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
      use old <- c.then(c.lookup(bindings, n))
      use t <- c.then(merge(old, t))
      Ok(c.put(bindings, n, t))
    }
    _, a.Unresolved -> Ok(bindings)
    a.ListType(l), a.ListType(r) -> infer(l, r, bindings)
    a.TupleType(l), a.TupleType(r) -> infer_many(l, r, bindings)
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
    a.VariableType(n) -> c.lookup(bindings, n)
    a.ListType(t) -> {
      use t <- c.then(substitute(t, bindings))
      Ok(a.ListType(t))
    }
    a.TupleType(types) -> {
      use types <- c.then(c.try_map(types, fn(t) { substitute(t, bindings) }))
      Ok(a.TupleType(types))
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
