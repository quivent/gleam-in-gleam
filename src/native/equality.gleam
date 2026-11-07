// Compile-time equality shape graph. Register a node before descending so
// regular recursive types share helpers; do not guess erased field layouts.
import native/ast as a
import native/core as c
import native/definitions as d
import native/type_system as types

pub type Shape {
  Pending
  Word
  Text
  Bits
  Tuple(List(Int))
  ListOf(Int)
  Nominal(List(Variant))
  // Empty-list/unused-constructor inference holes have no stored value.
  // If one is reached at runtime, fail closed rather than compare as a word.
  Uninhabited
}

pub type Variant {
  Variant(tag: Int, fields: List(Int))
}

pub type Entry {
  Entry(id: Int, type_: a.Type, shape: Shape)
}

pub type Plan {
  Plan(root: Int, entries: List(Entry))
}

pub fn plan(type_: a.Type, globals: d.Context) -> Result(Plan, String) {
  use #(root, entries) <- c.then(visit(type_, globals, []))
  Ok(Plan(root, c.reverse(entries)))
}

fn find(type_: a.Type, entries: List(Entry)) -> Result(Int, String) {
  case entries {
    [] -> Error("No equality shape")
    [entry, ..rest] ->
      case entry.type_ == type_ {
        True -> Ok(entry.id)
        False -> find(type_, rest)
      }
  }
}

fn visit(
  type_: a.Type,
  globals: d.Context,
  entries: List(Entry),
) -> Result(#(Int, List(Entry)), String) {
  case find(type_, entries) {
    Ok(id) -> Ok(#(id, entries))
    Error(_) -> {
      let id = c.length(entries)
      use _ <- c.then(case id >= 128 {
        True ->
          Error(
            "Equality shape expansion limit reached: non-regular recursive or excessively large types are not supported",
          )
        False -> Ok(Nil)
      })
      let entries = [Entry(id, type_, Pending), ..entries]
      use #(shape, entries) <- c.then(shape(type_, globals, entries))
      Ok(#(id, replace(entries, id, shape)))
    }
  }
}

fn replace(entries: List(Entry), id: Int, shape: Shape) -> List(Entry) {
  c.map(entries, fn(e) {
    case e.id == id {
      True -> Entry(..e, shape: shape)
      False -> e
    }
  })
}

fn shape(
  t: a.Type,
  globals: d.Context,
  entries: List(Entry),
) -> Result(#(Shape, List(Entry)), String) {
  case t {
    a.Integer | a.Boolean | a.Unit -> Ok(#(Word, entries))
    a.StringType -> Ok(#(Text, entries))
    a.BitArrayType -> Ok(#(Bits, entries))
    a.Unresolved -> Ok(#(Uninhabited, entries))
    a.VariableType(_) ->
      Error(
        "Structural equality requires concrete stored field types; erased type parameters are not supported",
      )
    a.FunctionType(_, _) -> Error("Function-value equality is not implemented")
    a.QualifiedType(_, _, _) -> Error("Unresolved module type in equality")
    a.ListType(element) -> {
      use #(child, entries) <- c.then(visit(element, globals, entries))
      Ok(#(ListOf(child), entries))
    }
    a.TupleType(fields) -> {
      use #(fields, entries) <- c.then(children(fields, globals, entries))
      Ok(#(Tuple(fields), entries))
    }
    a.NamedType(name) -> nominal(name, [], globals, entries)
    a.AppliedType(name, args) -> nominal(name, args, globals, entries)
  }
}

fn children(
  fields: List(a.Type),
  globals: d.Context,
  entries: List(Entry),
) -> Result(#(List(Int), List(Entry)), String) {
  case fields {
    [] -> Ok(#([], entries))
    [t, ..rest] -> {
      use #(id, entries) <- c.then(visit(t, globals, entries))
      use #(tail, entries) <- c.then(children(rest, globals, entries))
      Ok(#([id, ..tail], entries))
    }
  }
}

fn nominal(
  name: String,
  args: List(a.Type),
  globals: d.Context,
  entries: List(Entry),
) -> Result(#(Shape, List(Entry)), String) {
  use definition <- c.then(c.lookup(globals.custom_types, name))
  use #(variants, entries) <- c.then(variants(
    definition.variants,
    args,
    globals,
    entries,
  ))
  Ok(#(Nominal(variants), entries))
}

fn variants(
  items: List(a.Variant),
  args: List(a.Type),
  globals: d.Context,
  entries: List(Entry),
) -> Result(#(List(Variant), List(Entry)), String) {
  case items {
    [] -> Ok(#([], entries))
    [item, ..rest] -> {
      use ctor <- c.then(c.lookup(globals.constructors, item.name))
      use bindings <- c.then(types.bindings(ctor.parameters, args))
      use fields <- c.then(
        c.try_map(ctor.fields, fn(t) { types.substitute(t, bindings) }),
      )
      use #(fields, entries) <- c.then(children(fields, globals, entries))
      use #(tail, entries) <- c.then(variants(rest, args, globals, entries))
      Ok(#([Variant(ctor.tag, fields), ..tail], entries))
    }
  }
}
