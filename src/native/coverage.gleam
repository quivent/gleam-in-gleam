// Product-pattern exhaustiveness for checked multi-subject/alternative cases.
// Only unguarded rows reach this pass. Infinite domains require a default row;
// finite constructors specialize into their fields without losing correlation.
import native/ast as a
import native/core as c
import native/definitions as d
import native/type_system as types

pub type Column {
  Column(type_: a.Type, known: Int)
}

type Choice {
  Choice(kind: Int, tag: Int, fields: List(Column))
}

type Selection {
  Miss
  Hit(List(a.Pattern))
}

pub fn complete(
  rows: List(List(a.Pattern)),
  columns: List(Column),
  globals: d.Context,
) -> Result(Nil, String) {
  use yes <- c.then(matrix(rows, columns, globals))
  case yes {
    True -> Ok(Nil)
    False ->
      Error(
        "Non-exhaustive multi-pattern case: add missing combinations or a catch-all row",
      )
  }
}

fn matrix(
  rows: List(List(a.Pattern)),
  columns: List(Column),
  globals: d.Context,
) -> Result(Bool, String) {
  case rows, columns {
    [], _ -> Ok(False)
    _, [] -> Ok(True)
    _, [column, ..rest] -> {
      // Avoid recursively expanding unconstrained recursive list/ADT columns.
      case all_first_wild(rows) {
        True -> matrix(default_rows(rows), rest, globals)
        False -> {
          use choices <- c.then(choices(column, globals))
          case choices {
            [] -> matrix(default_rows(rows), rest, globals)
            _ -> each_choice(choices, rows, rest, globals)
          }
        }
      }
    }
  }
}

fn wild(p: a.Pattern) -> Bool {
  case p {
    a.VariablePattern(_) | a.DiscardPattern -> True
    a.ListPattern([], a.RestPattern(p)) -> wild(p)
    a.CheckedBitArrayPattern([#(p, a.BitsSegment)]) -> wild(p)
    _ -> False
  }
}

fn all_first_wild(rows: List(List(a.Pattern))) -> Bool {
  case rows {
    [] -> True
    [[p, ..], ..rest] -> wild(p) && all_first_wild(rest)
    _ -> False
  }
}

fn default_rows(rows: List(List(a.Pattern))) -> List(List(a.Pattern)) {
  case rows {
    [] -> []
    [[p, ..tail], ..rest] ->
      case wild(p) {
        True -> [tail, ..default_rows(rest)]
        False -> default_rows(rest)
      }
    _ -> []
  }
}

fn choices(column: Column, globals: d.Context) -> Result(List(Choice), String) {
  case column.type_ {
    a.Boolean -> Ok([Choice(0, 0, []), Choice(0, 1, [])])
    a.TupleType(fields) ->
      Ok([Choice(1, 0, c.map(fields, fn(t) { Column(t, 0) }))])
    a.ListType(element) ->
      Ok([
        Choice(2, 0, []),
        Choice(2, 1, [Column(element, 0), Column(column.type_, 0)]),
      ])
    a.NamedType(owner) -> constructors(owner, [], column.known, globals)
    a.AppliedType(owner, args) ->
      constructors(owner, args, column.known, globals)
    _ -> Ok([])
  }
}

fn constructors(
  owner: String,
  args: List(a.Type),
  known: Int,
  globals: d.Context,
) -> Result(List(Choice), String) {
  use definition <- c.then(c.lookup(globals.custom_types, owner))
  constructor_choices(definition.variants, args, known, globals)
}

fn constructor_choices(
  variants: List(a.Variant),
  args: List(a.Type),
  known: Int,
  globals: d.Context,
) -> Result(List(Choice), String) {
  case variants {
    [] -> Ok([])
    [variant, ..rest] -> {
      use ctor <- c.then(c.lookup(globals.constructors, variant.name))
      use tail <- c.then(constructor_choices(rest, args, known, globals))
      case known == 0 || known == ctor.tag {
        False -> Ok(tail)
        True -> {
          use bindings <- c.then(types.bindings(ctor.parameters, args))
          use fields <- c.then(
            c.try_map(ctor.fields, fn(t) { types.substitute(t, bindings) }),
          )
          Ok([
            Choice(3, ctor.tag, c.map(fields, fn(t) { Column(t, 0) })),
            ..tail
          ])
        }
      }
    }
  }
}

fn each_choice(
  choices: List(Choice),
  rows: List(List(a.Pattern)),
  rest: List(Column),
  globals: d.Context,
) -> Result(Bool, String) {
  case choices {
    [] -> Ok(True)
    [choice, ..tail] -> {
      use specialized <- c.then(specialize(rows, choice))
      use yes <- c.then(matrix(
        specialized,
        c.append(choice.fields, rest),
        globals,
      ))
      case yes {
        False -> Ok(False)
        True -> each_choice(tail, rows, rest, globals)
      }
    }
  }
}

fn specialize(
  rows: List(List(a.Pattern)),
  choice: Choice,
) -> Result(List(List(a.Pattern)), String) {
  case rows {
    [] -> Ok([])
    [[p, ..tail], ..rest] -> {
      use selected <- c.then(select(p, choice))
      use rows <- c.then(specialize(rest, choice))
      case selected {
        Miss -> Ok(rows)
        Hit(fields) -> Ok([c.append(fields, tail), ..rows])
      }
    }
    _ -> Error("Internal pattern matrix arity mismatch")
  }
}

fn select(p: a.Pattern, choice: Choice) -> Result(Selection, String) {
  case wild(p) {
    True -> Ok(Hit(c.map(choice.fields, fn(_) { a.DiscardPattern })))
    False ->
      case p {
        a.BooleanPattern(b) ->
          case
            choice.kind == 0
            && choice.tag
            == {
              case b {
                True -> 1
                False -> 0
              }
            }
          {
            True -> Ok(Hit([]))
            False -> Ok(Miss)
          }
        a.TuplePattern(fields) ->
          case choice.kind == 1 {
            True -> Ok(Hit(fields))
            False -> Ok(Miss)
          }
        a.CheckedConstructorPattern(tag, fields) ->
          case choice.kind == 3 && choice.tag == tag {
            True -> Ok(Hit(c.map(fields, fn(f) { f.0 })))
            False -> Ok(Miss)
          }
        a.ListPattern([], a.NoPatternRest) ->
          case choice.kind == 2 && choice.tag == 0 {
            True -> Ok(Hit([]))
            False -> Ok(Miss)
          }
        a.ListPattern([], a.RestPattern(tail)) -> select(tail, choice)
        a.ListPattern([head, ..tail], rest) ->
          case choice.kind == 2 && choice.tag == 1 {
            True -> Ok(Hit([head, a.ListPattern(tail, rest)]))
            False -> Ok(Miss)
          }
        _ -> Ok(Miss)
      }
  }
}
