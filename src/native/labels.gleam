import native/core as c

pub type Missing(a) {
  RejectMissing
  FillMissing(a)
}

// Gleam evaluates constructor arguments after arranging them in declaration order.
// This module performs only name/position validation and produces that order.
pub fn order(
  provided: List(#(String, a)),
  labels: List(String),
  missing: Missing(a),
) -> Result(List(a), String) {
  use assigned <- c.then(assign(provided, labels, 0, False, []))
  complete(labels, 0, assigned, missing)
}

fn assign(
  provided: List(#(String, a)),
  labels: List(String),
  positional: Int,
  labelled: Bool,
  assigned: List(#(String, a)),
) -> Result(List(#(String, a)), String) {
  case provided {
    [] -> Ok(assigned)
    [#(label, value), ..rest] -> {
      use index <- c.then(case label {
        "" ->
          case labelled {
            True -> Error("Positional argument after labelled argument")
            False ->
              case positional < c.length(labels) {
                True -> Ok(positional)
                False -> Error("Constructor argument count mismatch")
              }
          }
        _ -> find_label(labels, label, 0)
      })
      let key = c.decimal(index)
      use _ <- c.then(case c.lookup(assigned, key) {
        Ok(_) -> Error("Duplicate constructor argument/field")
        Error(_) -> Ok(Nil)
      })
      let next = case label {
        "" -> positional + 1
        _ -> positional
      }
      assign(rest, labels, next, labelled || label != "", [
        #(key, value),
        ..assigned
      ])
    }
  }
}

fn find_label(
  labels: List(String),
  name: String,
  index: Int,
) -> Result(Int, String) {
  case labels {
    [] -> Error("Unknown constructor label: " <> name)
    [label, ..rest] ->
      case label == name {
        True -> Ok(index)
        False -> find_label(rest, name, index + 1)
      }
  }
}

pub fn index(labels: List(String), name: String) -> Result(Int, String) {
  find_label(labels, name, 0)
}

fn complete(
  labels: List(String),
  index: Int,
  assigned: List(#(String, a)),
  missing: Missing(a),
) -> Result(List(a), String) {
  case labels {
    [] -> Ok([])
    [_, ..rest] -> {
      use value <- c.then(case c.lookup(assigned, c.decimal(index)) {
        Ok(value) -> Ok(value)
        Error(_) ->
          case missing {
            FillMissing(value) -> Ok(value)
            RejectMissing ->
              Error("Constructor argument count mismatch: missing field")
          }
      })
      use tail <- c.then(complete(rest, index + 1, assigned, missing))
      Ok([value, ..tail])
    }
  }
}
