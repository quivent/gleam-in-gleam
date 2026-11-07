import native/ast as a
import native/core as c
import native/lexer as l

type Tokens =
  List(l.Token)

type Parsed(t) =
  Result(#(t, Tokens), String)

fn error(tokens: Tokens, message: String) -> Result(t, String) {
  case tokens {
    [l.Token(_, at), ..] -> Error("byte " <> c.decimal(at) <> ": " <> message)
    [] -> Error("end of input: " <> message)
  }
}

fn expect(tokens: Tokens, symbol: String) -> Result(Tokens, String) {
  case tokens {
    [l.Token(l.Symbol(s), _), ..rest] if s == symbol -> Ok(rest)
    _ -> error(tokens, "Expected '" <> symbol <> "'")
  }
}

fn name(tokens: Tokens) -> Parsed(String) {
  case tokens {
    [l.Token(l.Word(s), _), ..rest] -> Ok(#(s, rest))
    _ -> error(tokens, "Expected identifier")
  }
}

fn type_(tokens: Tokens) -> Parsed(a.Type) {
  case tokens {
    [l.Token(l.Word("Int"), _), ..rest] -> Ok(#(a.Integer, rest))
    [l.Token(l.Word("Bool"), _), ..rest] -> Ok(#(a.Boolean, rest))
    [l.Token(l.Word("Nil"), _), ..rest] -> Ok(#(a.Unit, rest))
    [l.Token(l.Word("String"), _), ..rest] -> Ok(#(a.StringType, rest))
    [l.Token(l.Word("List"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(element, rest) <- c.then(type_(rest))
      use rest <- c.then(expect(rest, ")"))
      Ok(#(a.ListType(element), rest))
    }
    [l.Token(l.Symbol("#"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(types, rest) <- c.then(separated(rest, ")", type_))
      Ok(#(a.TupleType(types), rest))
    }
    [l.Token(l.Word(id), _), ..rest] ->
      case c.uppercase_name(id) {
        True -> Ok(#(a.NamedType(id), rest))
        False -> error(tokens, "Generic type variables are not implemented yet")
      }
    _ ->
      error(
        tokens,
        "Type not implemented in native seed (supported: Int, Bool, Nil, String, List, tuples)",
      )
  }
}

pub fn parse(tokens: Tokens) -> Result(a.Module, String) {
  functions(tokens, [], [])
}

fn functions(
  tokens: Tokens,
  acc: List(a.Function),
  types: List(a.CustomType),
) -> Result(a.Module, String) {
  case tokens {
    [l.Token(l.End, _)] -> Ok(a.Module(c.reverse(acc), c.reverse(types)))
    [l.Token(l.Word("pub"), _), ..rest] -> declaration(rest, acc, types, True)
    _ -> declaration(tokens, acc, types, False)
  }
}

fn declaration(
  tokens: Tokens,
  acc: List(a.Function),
  types: List(a.CustomType),
  public_: Bool,
) -> Result(a.Module, String) {
  case tokens {
    [l.Token(l.Word("type"), _), ..rest] -> {
      use #(id, rest) <- c.then(name(rest))
      use rest <- c.then(expect(rest, "{"))
      use #(variants, rest) <- c.then(variants(rest, []))
      functions(rest, acc, [a.CustomType(id, variants, public_), ..types])
    }
    [l.Token(l.Word("fn"), _), ..rest] -> {
      use #(id, rest) <- c.then(name(rest))
      use rest <- c.then(expect(rest, "("))
      use #(params, rest) <- c.then(parameters(rest, []))
      use rest <- c.then(expect(rest, "->"))
      use #(return_type, rest) <- c.then(type_(rest))
      use rest <- c.then(expect(rest, "{"))
      use #(body, rest) <- c.then(statements(rest, []))
      functions(
        rest,
        [a.Function(id, params, return_type, body, public_), ..acc],
        types,
      )
    }
    _ ->
      error(
        tokens,
        "Declaration not implemented in native seed; expected a function with explicit parameter/return types",
      )
  }
}

fn variants(tokens: Tokens, acc: List(a.Variant)) -> Parsed(List(a.Variant)) {
  case tokens {
    [l.Token(l.Symbol("}"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    _ -> {
      use #(id, rest) <- c.then(name(tokens))
      case rest {
        [l.Token(l.Symbol("("), _), ..rest] -> {
          use #(fields, rest) <- c.then(separated(rest, ")", type_))
          variants(rest, [a.Variant(id, fields), ..acc])
        }
        _ -> variants(rest, [a.Variant(id, []), ..acc])
      }
    }
  }
}

fn parameters(
  tokens: Tokens,
  acc: List(#(String, a.Type)),
) -> Parsed(List(#(String, a.Type))) {
  case tokens {
    [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    _ -> {
      use #(id, rest) <- c.then(name(tokens))
      use rest <- c.then(expect(rest, ":"))
      use #(t, rest) <- c.then(type_(rest))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] ->
          parameters(rest, [#(id, t), ..acc])
        [l.Token(l.Symbol(")"), _), ..rest] ->
          Ok(#(c.reverse([#(id, t), ..acc]), rest))
        _ -> error(rest, "Expected ',' or ')' in parameter list")
      }
    }
  }
}

fn annotation(tokens: Tokens) -> Parsed(a.Annotation) {
  case tokens {
    [l.Token(l.Symbol(":"), _), ..rest] -> {
      use #(t, rest) <- c.then(type_(rest))
      Ok(#(a.Annotated(t), rest))
    }
    _ -> Ok(#(a.Inferred, tokens))
  }
}

fn statements(
  tokens: Tokens,
  acc: List(a.Statement),
) -> Parsed(List(a.Statement)) {
  case tokens {
    [l.Token(l.Symbol("}"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    [l.Token(l.Word("let"), _), ..rest] -> {
      use #(pat, rest) <- c.then(pattern(rest))
      use #(t, rest) <- c.then(annotation(rest))
      use rest <- c.then(expect(rest, "="))
      use #(value, rest) <- c.then(expression(rest, 0))
      statements(rest, [a.Bind(pat, t, value), ..acc])
    }
    _ -> {
      use #(value, rest) <- c.then(expression(tokens, 0))
      statements(rest, [a.Evaluate(value), ..acc])
    }
  }
}

fn expression(tokens: Tokens, minimum: Int) -> Parsed(a.Expression) {
  use #(left, rest) <- c.then(prefix(tokens))
  use #(left, rest) <- c.then(postfix(left, rest))
  infix(left, rest, minimum)
}

fn postfix(left: a.Expression, tokens: Tokens) -> Parsed(a.Expression) {
  case tokens {
    [l.Token(l.Symbol("."), _), l.Token(l.Number(index), _), ..rest] ->
      postfix(a.TupleIndex(left, index), rest)
    _ -> Ok(#(left, tokens))
  }
}

fn separated(
  tokens: Tokens,
  end: String,
  item: fn(Tokens) -> Parsed(t),
) -> Parsed(List(t)) {
  case tokens {
    [l.Token(l.Symbol(symbol), _), ..rest] if symbol == end -> Ok(#([], rest))
    _ -> {
      use #(value, rest) <- c.then(item(tokens))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> {
          use #(tail, rest) <- c.then(separated(rest, end, item))
          Ok(#([value, ..tail], rest))
        }
        [l.Token(l.Symbol(symbol), _), ..rest] if symbol == end ->
          Ok(#([value], rest))
        _ -> error(rest, "Expected ',' or '" <> end <> "'")
      }
    }
  }
}

fn precedence(op: String) -> Int {
  case op {
    "||" -> 1
    "&&" -> 2
    "==" | "!=" -> 3
    "<" | "<=" | ">" | ">=" -> 4
    "+" | "-" -> 5
    "*" | "/" | "%" -> 6
    _ -> -1
  }
}

fn infix(
  left: a.Expression,
  tokens: Tokens,
  minimum: Int,
) -> Parsed(a.Expression) {
  case tokens {
    [l.Token(l.Symbol(op), _), ..rest] -> {
      let power = precedence(op)
      case power >= minimum {
        False -> Ok(#(left, tokens))
        True -> {
          use #(right, rest) <- c.then(expression(rest, power + 1))
          infix(a.Binary(op, left, right), rest, minimum)
        }
      }
    }
    _ -> Ok(#(left, tokens))
  }
}

fn prefix(tokens: Tokens) -> Parsed(a.Expression) {
  case tokens {
    [l.Token(l.Number(n), _), ..rest] -> Ok(#(a.IntegerLiteral(n), rest))
    [l.Token(l.Text(s), _), ..rest] -> Ok(#(a.StringLiteral(s), rest))
    [l.Token(l.Symbol("#"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(elements, rest) <- c.then(
        separated(rest, ")", fn(ts) { expression(ts, 0) }),
      )
      Ok(#(a.TupleLiteral(elements), rest))
    }
    [l.Token(l.Symbol("["), _), ..rest] -> {
      use #(items, tail, rest) <- c.then(list_expression(rest))
      Ok(#(a.ListLiteral(items, tail), rest))
    }
    [l.Token(l.Word("True"), _), ..rest] -> Ok(#(a.BooleanLiteral(True), rest))
    [l.Token(l.Word("False"), _), ..rest] ->
      Ok(#(a.BooleanLiteral(False), rest))
    [l.Token(l.Word("Nil"), _), ..rest] -> Ok(#(a.UnitLiteral, rest))
    [l.Token(l.Word("echo"), _), ..rest] -> {
      use #(e, rest) <- c.then(expression(rest, 0))
      Ok(#(a.Echo(e), rest))
    }
    [l.Token(l.Word("case"), _), ..rest] -> {
      use #(subject, rest) <- c.then(expression(rest, 0))
      use rest <- c.then(expect(rest, "{"))
      use #(arms, rest) <- c.then(arms(rest, []))
      Ok(#(a.Case(subject, arms), rest))
    }
    [l.Token(l.Word(id), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(args, rest) <- c.then(arguments(rest, []))
      Ok(#(a.Call(id, args), rest))
    }
    [l.Token(l.Word(id), _), ..rest] -> Ok(#(a.Variable(id), rest))
    [l.Token(l.Symbol(op), _), ..rest] if op == "-" || op == "!" -> {
      use #(e, rest) <- c.then(expression(rest, 7))
      Ok(#(a.Unary(op, e), rest))
    }
    [l.Token(l.Symbol("{"), _), ..rest] -> {
      use #(body, rest) <- c.then(statements(rest, []))
      Ok(#(a.Block(body), rest))
    }
    _ -> error(tokens, "Expression not implemented in native seed")
  }
}

fn arguments(
  tokens: Tokens,
  acc: List(a.Expression),
) -> Parsed(List(a.Expression)) {
  case tokens {
    [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    _ -> {
      use #(arg, rest) <- c.then(expression(tokens, 0))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> arguments(rest, [arg, ..acc])
        [l.Token(l.Symbol(")"), _), ..rest] ->
          Ok(#(c.reverse([arg, ..acc]), rest))
        _ -> error(rest, "Expected ',' or ')' in call")
      }
    }
  }
}

fn pattern(tokens: Tokens) -> Parsed(a.Pattern) {
  case tokens {
    [l.Token(l.Word(id), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(fields, rest) <- c.then(separated(rest, ")", pattern))
      case c.uppercase_name(id) {
        True -> Ok(#(a.ConstructorPattern(id, fields), rest))
        False -> error(tokens, "Constructor patterns must start with uppercase")
      }
    }
    [l.Token(l.Symbol("#"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(elements, rest) <- c.then(separated(rest, ")", pattern))
      Ok(#(a.TuplePattern(elements), rest))
    }
    [l.Token(l.Symbol("["), _), ..rest] -> {
      use #(elements, tail, rest) <- c.then(list_pattern(rest))
      Ok(#(a.ListPattern(elements, tail), rest))
    }
    [l.Token(l.Number(n), _), ..rest] -> Ok(#(a.IntegerPattern(n), rest))
    [l.Token(l.Symbol("-"), _), l.Token(l.Number(n), _), ..rest] ->
      Ok(#(a.IntegerPattern(0 - n), rest))
    [l.Token(l.Word("True"), _), ..rest] -> Ok(#(a.BooleanPattern(True), rest))
    [l.Token(l.Word("False"), _), ..rest] ->
      Ok(#(a.BooleanPattern(False), rest))
    [l.Token(l.Word("_"), _), ..rest] -> Ok(#(a.DiscardPattern, rest))
    [l.Token(l.Word(id), _), ..rest] ->
      case c.uppercase_name(id) {
        True -> Ok(#(a.ConstructorPattern(id, []), rest))
        False -> Ok(#(a.VariablePattern(id), rest))
      }
    _ -> error(tokens, "Pattern not implemented in native seed")
  }
}

fn list_expression(
  tokens: Tokens,
) -> Result(#(List(a.Expression), a.ListRest, Tokens), String) {
  case tokens {
    [l.Token(l.Symbol("]"), _), ..rest] -> Ok(#([], a.NoRest, rest))
    [l.Token(l.Symbol(".."), _), ..rest] -> {
      use #(tail, rest) <- c.then(expression(rest, 0))
      use rest <- c.then(expect(rest, "]"))
      Ok(#([], a.Rest(tail), rest))
    }
    _ -> {
      use #(head, rest) <- c.then(expression(tokens, 0))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> {
          use #(items, tail, rest) <- c.then(list_expression(rest))
          Ok(#([head, ..items], tail, rest))
        }
        [l.Token(l.Symbol("]"), _), ..rest] -> Ok(#([head], a.NoRest, rest))
        _ -> error(rest, "Expected ',' or ']' in list")
      }
    }
  }
}

fn list_pattern(
  tokens: Tokens,
) -> Result(#(List(a.Pattern), a.PatternRest, Tokens), String) {
  case tokens {
    [l.Token(l.Symbol(".."), _), l.Token(l.Symbol("]"), _), ..rest] ->
      Ok(#([], a.RestPattern(a.DiscardPattern), rest))
    [l.Token(l.Symbol("]"), _), ..rest] -> Ok(#([], a.NoPatternRest, rest))
    [l.Token(l.Symbol(".."), _), ..rest] -> {
      use #(tail, rest) <- c.then(pattern(rest))
      use rest <- c.then(expect(rest, "]"))
      Ok(#([], a.RestPattern(tail), rest))
    }
    _ -> {
      use #(head, rest) <- c.then(pattern(tokens))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> {
          use #(items, tail, rest) <- c.then(list_pattern(rest))
          Ok(#([head, ..items], tail, rest))
        }
        [l.Token(l.Symbol("]"), _), ..rest] ->
          Ok(#([head], a.NoPatternRest, rest))
        _ -> error(rest, "Expected ',' or ']' in list pattern")
      }
    }
  }
}

fn arms(tokens: Tokens, acc: List(a.Arm)) -> Parsed(List(a.Arm)) {
  case tokens {
    [l.Token(l.Symbol("}"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    _ -> {
      use #(pat, rest) <- c.then(pattern(tokens))
      use rest <- c.then(expect(rest, "->"))
      use #(body, rest) <- c.then(expression(rest, 0))
      arms(rest, [a.Arm(pat, body), ..acc])
    }
  }
}
