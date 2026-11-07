import native/ast as a
import native/core as c

pub type Constructor {
  Constructor(
    name: String,
    owner: String,
    tag: Int,
    fields: List(a.Type),
    parameters: List(String),
    labels: List(String),
  )
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
        use _ <- c.then(validate_type_in(t, context, owner.parameters))
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
      use _ <- c.then(parameter_names(t.parameters, []))
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
      use #(acc, next) <- c.then(variants(
        t.variants,
        t.name,
        t.parameters,
        acc,
        next,
      ))
      constructor_index(rest, acc, next)
    }
  }
}

fn variants(
  items: List(a.Variant),
  owner: String,
  params: List(String),
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
      use _ <- c.then(field_labels(v.fields, []))
      let constructor =
        Constructor(
          v.name,
          owner,
          next,
          c.map(v.fields, fn(f) { f.type_ }),
          params,
          c.map(v.fields, fn(f) { f.label }),
        )
      variants(rest, owner, params, [#(v.name, constructor), ..acc], next + 1)
    }
  }
}

fn field_labels(
  fields: List(a.FieldDefinition),
  seen: List(#(String, Nil)),
) -> Result(Nil, String) {
  case fields {
    [] -> Ok(Nil)
    [a.FieldDefinition("", _), ..rest] -> field_labels(rest, seen)
    [field, ..rest] ->
      case c.uppercase_name(field.label) {
        True -> Error("Field labels must start with lowercase")
        False ->
          case c.lookup(seen, field.label) {
            Ok(_) -> Error("Duplicate field label: " <> field.label)
            Error(_) -> field_labels(rest, [#(field.label, Nil), ..seen])
          }
      }
  }
}

pub fn validate_type(type_: a.Type, context: Context) -> Result(Nil, String) {
  validate_type_in(type_, context, [])
}

fn validate_type_in(
  type_: a.Type,
  context: Context,
  params: List(String),
) -> Result(Nil, String) {
  case type_ {
    a.NamedType(name) -> validate_application(name, [], context, params)
    a.AppliedType(name, args) ->
      validate_application(name, args, context, params)
    a.VariableType(name) ->
      case c.lookup(c.map(params, fn(p) { #(p, Nil) }), name) {
        Ok(_) -> Ok(Nil)
        Error(_) ->
          Error(
            "Unbound type parameter (generic function signatures are not implemented): "
            <> name,
          )
      }
    a.ListType(element) -> validate_type_in(element, context, params)
    a.TupleType(elements) -> {
      use _ <- c.then(
        c.try_map(elements, fn(t) { validate_type_in(t, context, params) }),
      )
      Ok(Nil)
    }
    a.Unresolved -> Error("Internal unresolved type is not a source annotation")
    _ -> Ok(Nil)
  }
}

fn validate_application(
  name: String,
  args: List(a.Type),
  context: Context,
  params: List(String),
) -> Result(Nil, String) {
  use definition <- c.then(case c.lookup(context.custom_types, name) {
    Ok(d) -> Ok(d)
    Error(_) -> Error("Unknown type: " <> name)
  })
  case c.length(args) == c.length(definition.parameters) {
    False -> Error("Type argument count mismatch: " <> name)
    True -> {
      use _ <- c.then(
        c.try_map(args, fn(t) { validate_type_in(t, context, params) }),
      )
      Ok(Nil)
    }
  }
}

fn parameter_names(
  params: List(String),
  seen: List(#(String, Nil)),
) -> Result(Nil, String) {
  case params {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case c.uppercase_name(name) || name == "_" {
        True -> Error("Type parameters must be named lowercase variables")
        False ->
          case c.lookup(seen, name) {
            Ok(_) -> Error("Duplicate type parameter: " <> name)
            Error(_) -> parameter_names(rest, [#(name, Nil), ..seen])
          }
      }
  }
}

fn public_type(type_: a.Type, context: Context) -> Result(Nil, String) {
  case type_ {
    a.AppliedType(name, args) -> {
      use _ <- c.then(public_type(a.NamedType(name), context))
      use _ <- c.then(c.try_map(args, fn(t) { public_type(t, context) }))
      Ok(Nil)
    }
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
