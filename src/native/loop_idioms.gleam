// Structural, effect-free loop recognition. Never select by a function's name.
import native/ast as a
import native/check as t

pub type Plan {
  ByteCount(source: String, accumulator: String)
}

pub fn recognize(function: t.Function) -> Result(Plan, String) {
  case function.result {
    a.Integer ->
      case function.parameters {
        [#(source, a.BitArrayType), #(counter, a.Integer)] ->
          body(function, source, counter, False)
        [#(counter, a.Integer), #(source, a.BitArrayType)] ->
          body(function, source, counter, True)
        _ -> Error("Not a byte-count loop signature")
      }
    _ -> Error("Not an integer result")
  }
}

fn body(
  function: t.Function,
  source: String,
  counter: String,
  reversed: Bool,
) -> Result(Plan, String) {
  case function.body {
    [t.Evaluate(value)] ->
      case value.node {
        t.CaseNode(subject, [first, last]) ->
          case subject.node {
            t.VariableNode(name) if name == source ->
              arms(function.name, first, last, source, counter, reversed)
            _ -> Error("Not a case on the source parameter")
          }
        _ -> Error("Not one complete case")
      }
    _ -> Error("Loop has other statements or effects")
  }
}

fn arms(
  self: String,
  first: t.Arm,
  last: t.Arm,
  source: String,
  counter: String,
  reversed: Bool,
) -> Result(Plan, String) {
  case last {
    t.Arm(a.DiscardPattern, a.NoGuard, base) ->
      case base.node {
        t.VariableNode(name) if name == counter ->
          case first {
            t.Arm(a.CheckedBitArrayPattern(segments), a.NoGuard, recursive) ->
              case segments {
                [
                  #(a.DiscardPattern, a.IntegerSegment(1, _, _)),
                  #(a.VariablePattern(tail), mode),
                ] ->
                  case mode {
                    a.BitsSegment | a.BytesSegment ->
                      case tail == counter {
                        True -> Error("Tail shadows the counter")
                        False ->
                          step(self, recursive, source, counter, tail, reversed)
                      }
                    _ -> Error("Not a complete byte tail")
                  }
                _ -> Error("Not a discarded single byte and tail")
              }
            _ -> Error("Not an unguarded byte pattern")
          }
        _ -> Error("Base arm changes the counter")
      }
    _ -> Error("Not a complete counter fallback")
  }
}

fn step(
  self: String,
  recursive: t.Typed,
  source: String,
  counter: String,
  tail: String,
  reversed: Bool,
) -> Result(Plan, String) {
  case recursive.node {
    t.CallNode(name, [first, second]) if name == self -> {
      let byte_argument = case reversed {
        True -> second
        False -> first
      }
      let counter_argument = case reversed {
        True -> first
        False -> second
      }
      case byte_argument.node {
        t.VariableNode(name) if name == tail ->
          case counter_argument.node {
            t.BinaryNode("+", left, right) ->
              case left.node {
                t.VariableNode(name) if name == counter ->
                  case right.node {
                    t.IntegerNode(1) -> Ok(ByteCount(source, counter))
                    _ -> Error("Counter step is not exactly one")
                  }
                _ -> Error("Not the unchanged counter plus one")
              }
            _ -> Error("Not a checked counter increment")
          }
        _ -> Error("Recursive argument is not the complete tail")
      }
    }
    _ -> Error("Not a direct self-call")
  }
}
