import native/ast as a
import native/core as c

pub type Constructor {
  Constructor(name: String, owner: String, tag: Int, fields: List(a.Type))
}

pub type Context {
  Context(
    functions: List(#(String, a.Function)),
    custom_types: List(#(String, a.CustomType)),
    constructors: List(#(String, Constructor)),
  )
}

pub fn collect(module: a.Module) -> Result(Context, String) {
  use types <- c.then(type_index(module.custom_types, []))
  use constructors <- c.then(constructor_index(module.custom_types, [], 3))
  let context =
    Context(
      c.map(module.functions, fn(f) { #(f.name, f) }),
      types,
      constructors,
    )
  use _ <- c.then(
    c.try_map(constructors, fn(entry) {
      use owner <- c.then(c.lookup(context.custom_types, entry.1.owner))
      c.try_map(entry.1.fields, fn(t) {
        use _ <- c.then(validate_type(t, context))
        case owner.public_ {
          True -> public_type(t, context)
          False -> Ok(Nil)
        }
      })
    }),
  )
  use _ <- c.then(
    c.try_map(module.functions, fn(f) {
      use _ <- c.then(
        c.try_map(f.parameters, fn(p) { validate_type(p.1, context) }),
      )
      use _ <- c.then(validate_type(f.result, context))
      use _ <- c.then(case f.public_ {
        True -> {
          use _ <- c.then(
            c.try_map(f.parameters, fn(p) { public_type(p.1, context) }),
          )
          public_type(f.result, context)
        }
        False -> Ok(Nil)
      })
      case c.uppercase_name(f.name) {
        True -> Error("Function names must start with lowercase: " <> f.name)
        False -> Ok(Nil)
      }
    }),
  )
  Ok(context)
}

fn type_index(
  types: List(a.CustomType),
  acc: List(#(String, a.CustomType)),
) -> Result(List(#(String, a.CustomType)), String) {
  case types {
    [] -> Ok(acc)
    [t, ..rest] -> {
      use _ <- c.then(case t.name {
        "Int" | "Bool" | "Nil" | "String" | "List" ->
          Error("Builtin type shadowing is not implemented: " <> t.name)
        _ ->
          case c.uppercase_name(t.name) {
            False -> Error("Type names must start with uppercase: " <> t.name)
            True ->
              case c.lookup(acc, t.name) {
                Ok(_) -> Error("Duplicate type: " <> t.name)
                Error(_) -> Ok(Nil)
              }
          }
      })
      case t.variants {
        [] -> Error("Empty custom types are not implemented yet")
        _ -> type_index(rest, [#(t.name, t), ..acc])
      }
    }
  }
}

fn constructor_index(
  types: List(a.CustomType),
  acc: List(#(String, Constructor)),
  next: Int,
) -> Result(List(#(String, Constructor)), String) {
  case types {
    [] -> Ok(acc)
    [t, ..rest] -> {
      use #(acc, next) <- c.then(variants(t.variants, t.name, acc, next))
      constructor_index(rest, acc, next)
    }
  }
}

fn variants(
  items: List(a.Variant),
  owner: String,
  acc: List(#(String, Constructor)),
  next: Int,
) -> Result(#(List(#(String, Constructor)), Int), String) {
  case items {
    [] -> Ok(#(acc, next))
    [v, ..rest] -> {
      use _ <- c.then(case v.name {
        "True" | "False" | "Nil" ->
          Error("Builtin constructor shadowing is not implemented: " <> v.name)
        _ ->
          case c.uppercase_name(v.name) {
            False -> Error("Constructors must start with uppercase: " <> v.name)
            True ->
              case c.lookup(acc, v.name) {
                Ok(_) -> Error("Duplicate constructor: " <> v.name)
                Error(_) -> Ok(Nil)
              }
          }
      })
      let constructor = Constructor(v.name, owner, next, v.fields)
      variants(rest, owner, [#(v.name, constructor), ..acc], next + 1)
    }
  }
}

pub fn validate_type(type_: a.Type, context: Context) -> Result(Nil, String) {
  case type_ {
    a.NamedType(name) ->
      case c.lookup(context.custom_types, name) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error("Unknown type: " <> name)
      }
    a.ListType(element) -> validate_type(element, context)
    a.TupleType(elements) -> {
      use _ <- c.then(c.try_map(elements, fn(t) { validate_type(t, context) }))
      Ok(Nil)
    }
    a.Unresolved -> Error("Internal unresolved type is not a source annotation")
    _ -> Ok(Nil)
  }
}

fn public_type(type_: a.Type, context: Context) -> Result(Nil, String) {
  case type_ {
    a.NamedType(name) -> {
      use definition <- c.then(c.lookup(context.custom_types, name))
      case definition.public_ {
        True -> Ok(Nil)
        False -> Error("Private type used in public interface: " <> name)
      }
    }
    a.ListType(t) -> public_type(t, context)
    a.TupleType(types) -> {
      use _ <- c.then(c.try_map(types, fn(t) { public_type(t, context) }))
      Ok(Nil)
    }
    _ -> Ok(Nil)
  }
}
