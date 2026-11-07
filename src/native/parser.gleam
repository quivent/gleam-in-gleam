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
    _ ->
      error(
        tokens,
        "Type not implemented in native seed (supported: Int, Bool, Nil, String)",
      )
  }
}

pub fn parse(tokens: Tokens) -> Result(a.Module, String) {
  functions(tokens, [])
}

fn functions(
  tokens: Tokens,
  acc: List(a.Function),
) -> Result(a.Module, String) {
  case tokens {
    [l.Token(l.End, _)] -> Ok(a.Module(c.reverse(acc)))
    [l.Token(l.Word("pub"), _), ..rest] -> functions(rest, acc)
    [l.Token(l.Word("fn"), _), ..rest] -> {
      use #(id, rest) <- c.then(name(rest))
      use rest <- c.then(expect(rest, "("))
      use #(params, rest) <- c.then(parameters(rest, []))
      use rest <- c.then(expect(rest, "->"))
      use #(return_type, rest) <- c.then(type_(rest))
      use rest <- c.then(expect(rest, "{"))
      use #(body, rest) <- c.then(statements(rest, []))
      functions(rest, [a.Function(id, params, return_type, body), ..acc])
    }
    _ ->
      error(
        tokens,
        "Declaration not implemented in native seed; expected a function with explicit parameter/return types",
      )
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
      use #(id, rest) <- c.then(name(rest))
      use #(t, rest) <- c.then(annotation(rest))
      use rest <- c.then(expect(rest, "="))
      use #(value, rest) <- c.then(expression(rest, 0))
      statements(rest, [a.Bind(id, t, value), ..acc])
    }
    _ -> {
      use #(value, rest) <- c.then(expression(tokens, 0))
      statements(rest, [a.Evaluate(value), ..acc])
    }
  }
}

fn expression(tokens: Tokens, minimum: Int) -> Parsed(a.Expression) {
  use #(left, rest) <- c.then(prefix(tokens))
  infix(left, rest, minimum)
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
    [l.Token(l.Number(n), _), ..rest] -> Ok(#(a.IntegerPattern(n), rest))
    [l.Token(l.Symbol("-"), _), l.Token(l.Number(n), _), ..rest] ->
      Ok(#(a.IntegerPattern(0 - n), rest))
    [l.Token(l.Word("True"), _), ..rest] -> Ok(#(a.BooleanPattern(True), rest))
    [l.Token(l.Word("False"), _), ..rest] ->
      Ok(#(a.BooleanPattern(False), rest))
    [l.Token(l.Word("_"), _), ..rest] -> Ok(#(a.DiscardPattern, rest))
    [l.Token(l.Word(id), _), ..rest] -> Ok(#(a.VariablePattern(id), rest))
    _ -> error(tokens, "Pattern not implemented in native seed")
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
