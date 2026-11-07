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
    [
      l.Token(l.Word(alias), _),
      l.Token(l.Symbol("."), _),
      l.Token(l.Word(member), _),
      ..rest
    ] -> {
      use #(args, rest) <- c.then(case rest {
        [l.Token(l.Symbol("("), _), ..rest] -> separated(rest, ")", type_)
        _ -> Ok(#([], rest))
      })
      Ok(#(a.QualifiedType(alias, member, args), rest))
    }
    [l.Token(l.Word("fn"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(params, rest) <- c.then(separated(rest, ")", type_))
      use rest <- c.then(expect(rest, "->"))
      use #(return_type, rest) <- c.then(type_(rest))
      Ok(#(a.FunctionType(params, return_type), rest))
    }
    [l.Token(l.Word("Int"), _), ..rest] -> Ok(#(a.Integer, rest))
    [l.Token(l.Word("Bool"), _), ..rest] -> Ok(#(a.Boolean, rest))
    [l.Token(l.Word("Nil"), _), ..rest] -> Ok(#(a.Unit, rest))
    [l.Token(l.Word("String"), _), ..rest] -> Ok(#(a.StringType, rest))
    [l.Token(l.Word("BitArray"), _), ..rest] -> Ok(#(a.BitArrayType, rest))
    [l.Token(l.Word("List"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(element, rest) <- c.then(type_(rest))
      use rest <- c.then(expect(rest, ")"))
      Ok(#(a.ListType(element), rest))
    }
    [l.Token(l.Symbol("#"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(types, rest) <- c.then(separated(rest, ")", type_))
      Ok(#(a.TupleType(types), rest))
    }
    [l.Token(l.Word(id), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(args, rest) <- c.then(separated(rest, ")", type_))
      case c.uppercase_name(id), args {
        True, [_, ..] -> Ok(#(a.AppliedType(id, args), rest))
        _, _ ->
          error(
            tokens,
            "Type application requires an uppercase name and nonempty arguments",
          )
      }
    }
    [l.Token(l.Word(id), _), ..rest] ->
      case c.uppercase_name(id) {
        True -> Ok(#(a.NamedType(id), rest))
        False -> Ok(#(a.VariableType(id), rest))
      }
    _ ->
      error(
        tokens,
        "Type not implemented in native seed (supported: Int, Bool, Nil, String, List, tuples)",
      )
  }
}

pub fn parse(tokens: Tokens) -> Result(a.Module, String) {
  functions(tokens, [], [], [], [])
}

fn functions(
  tokens: Tokens,
  acc: List(a.Function),
  types: List(a.CustomType),
  imports: List(a.Import),
  aliases: List(a.TypeAlias),
) -> Result(a.Module, String) {
  case tokens {
    [l.Token(l.End, _)] ->
      Ok(a.Module(
        c.reverse(acc),
        c.reverse(types),
        c.reverse(imports),
        c.reverse(aliases),
      ))
    [l.Token(l.Word("import"), _), ..rest] -> {
      use #(segments, rest) <- c.then(import_path(rest))
      let module_name = c.join(segments, "/")
      use #(default_alias, _) <- c.then(last_path(segments))
      use #(alias, rest) <- c.then(case rest {
        [l.Token(l.Word("as"), _), ..rest] -> name(rest)
        _ -> Ok(#(default_alias, rest))
      })
      functions(
        rest,
        acc,
        types,
        [a.Import(module_name, alias), ..imports],
        aliases,
      )
    }
    [l.Token(l.Word("pub"), _), ..rest] ->
      declaration(rest, acc, types, imports, aliases, True)
    _ -> declaration(tokens, acc, types, imports, aliases, False)
  }
}

fn declaration(
  tokens: Tokens,
  acc: List(a.Function),
  types: List(a.CustomType),
  imports: List(a.Import),
  aliases: List(a.TypeAlias),
  public_: Bool,
) -> Result(a.Module, String) {
  case tokens {
    [l.Token(l.Word("type"), _), ..rest] -> {
      use #(id, rest) <- c.then(name(rest))
      use #(params, rest) <- c.then(type_parameters(rest))
      case rest {
        [l.Token(l.Symbol("="), _), ..rest] -> {
          use #(value, rest) <- c.then(type_(rest))
          functions(rest, acc, types, imports, [
            a.TypeAlias(id, params, value, public_),
            ..aliases
          ])
        }
        _ -> {
          use rest <- c.then(expect(rest, "{"))
          use #(variants, rest) <- c.then(variants(rest, []))
          functions(
            rest,
            acc,
            [a.CustomType(id, variants, public_, params), ..types],
            imports,
            aliases,
          )
        }
      }
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
        imports,
        aliases,
      )
    }
    _ ->
      error(
        tokens,
        "Declaration not implemented in native seed; expected a function with explicit parameter/return types",
      )
  }
}

fn type_parameters(tokens: Tokens) -> Parsed(List(String)) {
  case tokens {
    [l.Token(l.Symbol("("), _), ..rest] -> {
      use #(params, rest) <- c.then(separated(rest, ")", name))
      case params {
        [] -> error(tokens, "Type parameter list cannot be empty")
        _ -> Ok(#(params, rest))
      }
    }
    _ -> Ok(#([], tokens))
  }
}

fn variants(tokens: Tokens, acc: List(a.Variant)) -> Parsed(List(a.Variant)) {
  case tokens {
    [l.Token(l.Symbol("}"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    _ -> {
      use #(id, rest) <- c.then(name(tokens))
      case rest {
        [l.Token(l.Symbol("("), _), ..rest] -> {
          use #(fields, rest) <- c.then(separated(rest, ")", field_definition))
          variants(rest, [a.Variant(id, fields), ..acc])
        }
        _ -> variants(rest, [a.Variant(id, []), ..acc])
      }
    }
  }
}

fn field_definition(tokens: Tokens) -> Parsed(a.FieldDefinition) {
  case tokens {
    [l.Token(l.Word(label), _), l.Token(l.Symbol(":"), _), ..rest] -> {
      use #(type_, rest) <- c.then(type_(rest))
      Ok(#(a.FieldDefinition(label, type_), rest))
    }
    _ -> {
      use #(type_, rest) <- c.then(type_(tokens))
      Ok(#(a.FieldDefinition("", type_), rest))
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
    [l.Token(l.Word("use"), _), ..rest] -> {
      use #(params, rest) <- c.then(use_parameters(rest))
      use #(target, rest) <- c.then(expression(rest, 0))
      use #(body, rest) <- c.then(statements(rest, []))
      case body {
        [] -> error(tokens, "use requires a following body expression")
        _ -> {
          let callback = a.Argument("", a.Lambda(params, a.Inferred, body))
          let call = case target {
            a.Call(name, args) -> a.Call(name, c.append(args, [callback]))
            a.Apply(function, args) ->
              a.Apply(function, c.append(args, [callback]))
            _ -> a.Apply(target, [callback])
          }
          Ok(#(c.append(c.reverse(acc), [a.Evaluate(call)]), rest))
        }
      }
    }
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
    [l.Token(l.Symbol("("), _), l.Token(l.Symbol(".."), _), ..rest] -> {
      use #(target, rest) <- c.then(expression(rest, 0))
      use #(args, rest) <- c.then(case rest {
        [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#([], rest))
        [l.Token(l.Symbol(","), _), ..rest] -> arguments(rest, [])
        _ -> error(rest, "Expected ',' or ')' after record update target")
      })
      case left {
        a.FieldAccess(a.Variable(alias), member) ->
          postfix(a.QualifiedRecordUpdate(alias, member, target, args), rest)
        _ -> error(tokens, "Record update requires a named constructor")
      }
    }
    [l.Token(l.Symbol("("), _), ..rest] -> {
      use #(args, rest) <- c.then(arguments(rest, []))
      postfix(a.Apply(left, args), rest)
    }
    [l.Token(l.Symbol("."), _), l.Token(l.Number(index), _), ..rest] ->
      postfix(a.TupleIndex(left, index), rest)
    [l.Token(l.Symbol("."), _), l.Token(l.Word(field), _), ..rest] ->
      postfix(a.FieldAccess(left, field), rest)
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
    "+" | "-" | "<>" -> 5
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
    [l.Token(l.Symbol("<<"), _), ..rest] -> {
      use #(segments, rest) <- c.then(
        bit_segments(rest, fn(ts) { expression(ts, 7) }),
      )
      Ok(#(a.BitArrayLiteral(segments), rest))
    }
    [l.Token(l.Word("fn"), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(params, rest) <- c.then(separated(rest, ")", lambda_parameter))
      use #(result, rest) <- c.then(case rest {
        [l.Token(l.Symbol("->"), _), ..rest] -> {
          use #(t, rest) <- c.then(type_(rest))
          Ok(#(a.Annotated(t), rest))
        }
        _ -> Ok(#(a.Inferred, rest))
      })
      use rest <- c.then(expect(rest, "{"))
      use #(body, rest) <- c.then(statements(rest, []))
      Ok(#(a.Lambda(params, result, body), rest))
    }
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
    [
      l.Token(l.Word(id), _),
      l.Token(l.Symbol("("), _),
      l.Token(l.Symbol(".."), _),
      ..rest
    ] -> {
      use #(target, rest) <- c.then(expression(rest, 0))
      use #(args, rest) <- c.then(case rest {
        [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#([], rest))
        [l.Token(l.Symbol(","), _), ..rest] -> arguments(rest, [])
        _ -> error(rest, "Expected ',' or ')' after record update target")
      })
      Ok(#(a.RecordUpdate(id, target, args), rest))
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
  acc: List(a.Argument),
) -> Parsed(List(a.Argument)) {
  case tokens {
    [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#(c.reverse(acc), rest))
    _ -> {
      use #(arg, rest) <- c.then(argument(tokens))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> arguments(rest, [arg, ..acc])
        [l.Token(l.Symbol(")"), _), ..rest] ->
          Ok(#(c.reverse([arg, ..acc]), rest))
        _ -> error(rest, "Expected ',' or ')' in call")
      }
    }
  }
}

fn argument(tokens: Tokens) -> Parsed(a.Argument) {
  case tokens {
    [l.Token(l.Word(label), _), l.Token(l.Symbol(":"), _), ..rest] ->
      case rest {
        [l.Token(l.Symbol(","), _), ..] | [l.Token(l.Symbol(")"), _), ..] ->
          Ok(#(a.Argument(label, a.Variable(label)), rest))
        _ -> {
          use #(value, rest) <- c.then(expression(rest, 0))
          Ok(#(a.Argument(label, value), rest))
        }
      }
    _ -> {
      use #(value, rest) <- c.then(expression(tokens, 0))
      Ok(#(a.Argument("", value), rest))
    }
  }
}

fn pattern(tokens: Tokens) -> Parsed(a.Pattern) {
  case tokens {
    [l.Token(l.Text(text), _), ..rest] -> {
      use #(binding, rest) <- c.then(case rest {
        [l.Token(l.Word("as"), _), ..rest] -> string_binding(rest)
        _ -> Ok(#(a.DiscardPattern, rest))
      })
      case rest {
        [l.Token(l.Symbol("<>"), _), ..rest] -> {
          use #(tail, rest) <- c.then(string_binding(rest))
          Ok(#(a.StringPrefixPattern(text, binding, tail), rest))
        }
        _ ->
          case binding {
            a.DiscardPattern -> Ok(#(a.StringPattern(text), rest))
            _ -> error(rest, "String prefix binding requires '<>'")
          }
      }
    }
    [
      l.Token(l.Word(alias), _),
      l.Token(l.Symbol("."), _),
      l.Token(l.Word(member), _),
      ..rest
    ] -> {
      use #(fields, spread, rest) <- c.then(case rest {
        [l.Token(l.Symbol("("), _), ..rest] -> constructor_patterns(rest)
        _ -> Ok(#([], False, rest))
      })
      Ok(#(a.ModuleConstructorPattern(alias, member, fields, spread), rest))
    }
    [l.Token(l.Symbol("<<"), _), ..rest] -> {
      use #(segments, rest) <- c.then(bit_segments(rest, pattern))
      Ok(#(a.BitArrayPattern(segments), rest))
    }
    [l.Token(l.Word(id), _), l.Token(l.Symbol("("), _), ..rest] -> {
      use #(fields, spread, rest) <- c.then(constructor_patterns(rest))
      case c.uppercase_name(id) {
        True -> Ok(#(a.ConstructorPattern(id, fields, spread), rest))
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
      case c.discarded_name(id), c.uppercase_name(id) {
        True, _ -> Ok(#(a.DiscardPattern, rest))
        _, True -> Ok(#(a.ConstructorPattern(id, [], False), rest))
        _, False -> Ok(#(a.VariablePattern(id), rest))
      }
    _ -> error(tokens, "Pattern not implemented in native seed")
  }
}

fn lambda_parameter(tokens: Tokens) -> Parsed(a.LambdaParameter) {
  use #(id, rest) <- c.then(name(tokens))
  use #(annotation, rest) <- c.then(annotation(rest))
  let pat = case c.discarded_name(id) {
    True -> a.DiscardPattern
    False -> a.VariablePattern(id)
  }
  Ok(#(a.LambdaParameter(pat, annotation), rest))
}

fn use_parameters(tokens: Tokens) -> Parsed(List(a.LambdaParameter)) {
  case tokens {
    [l.Token(l.Symbol("<-"), _), ..rest] -> Ok(#([], rest))
    _ -> {
      use #(pat, rest) <- c.then(pattern(tokens))
      use #(annotation, rest) <- c.then(annotation(rest))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> {
          use #(tail, rest) <- c.then(use_parameters(rest))
          Ok(#([a.LambdaParameter(pat, annotation), ..tail], rest))
        }
        [l.Token(l.Symbol("<-"), _), ..rest] ->
          Ok(#([a.LambdaParameter(pat, annotation)], rest))
        _ -> error(rest, "Expected ',' or '<-' after use patterns")
      }
    }
  }
}

fn constructor_patterns(
  tokens: Tokens,
) -> Result(#(List(a.PatternField), Bool, Tokens), String) {
  case tokens {
    [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#([], False, rest))
    [l.Token(l.Symbol(".."), _), l.Token(l.Symbol(")"), _), ..rest] ->
      Ok(#([], True, rest))
    _ -> {
      use #(field, rest) <- c.then(pattern_field(tokens))
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> {
          use #(tail, spread, rest) <- c.then(constructor_patterns(rest))
          Ok(#([field, ..tail], spread, rest))
        }
        [l.Token(l.Symbol(")"), _), ..rest] -> Ok(#([field], False, rest))
        _ -> error(rest, "Expected ',' or ')' in constructor pattern")
      }
    }
  }
}

fn pattern_field(tokens: Tokens) -> Parsed(a.PatternField) {
  case tokens {
    [l.Token(l.Word(label), _), l.Token(l.Symbol(":"), _), ..rest] ->
      case rest {
        [l.Token(l.Symbol(","), _), ..] | [l.Token(l.Symbol(")"), _), ..] ->
          Ok(#(a.PatternField(label, a.VariablePattern(label)), rest))
        _ -> {
          use #(pat, rest) <- c.then(pattern(rest))
          Ok(#(a.PatternField(label, pat), rest))
        }
      }
    _ -> {
      use #(pat, rest) <- c.then(pattern(tokens))
      Ok(#(a.PatternField("", pat), rest))
    }
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
      use #(guard, rest) <- c.then(case rest {
        [l.Token(l.Word("if"), _), ..rest] -> {
          use #(guard, rest) <- c.then(expression(rest, 0))
          Ok(#(a.Guard(guard), rest))
        }
        _ -> Ok(#(a.NoGuard, rest))
      })
      use rest <- c.then(expect(rest, "->"))
      use #(body, rest) <- c.then(expression(rest, 0))
      arms(rest, [a.Arm(pat, guard, body), ..acc])
    }
  }
}

fn bit_segments(
  tokens: Tokens,
  value: fn(Tokens) -> Parsed(t),
) -> Parsed(List(a.BitSegment(t))) {
  case tokens {
    [l.Token(l.Symbol(">>"), _), ..rest] -> Ok(#([], rest))
    _ -> {
      use #(item, rest) <- c.then(value(tokens))
      use #(options, rest) <- c.then(case rest {
        [l.Token(l.Symbol(":"), _), ..rest] -> bit_options(rest)
        _ -> Ok(#([], rest))
      })
      let segment = a.BitSegment(item, options)
      case rest {
        [l.Token(l.Symbol(","), _), ..rest] -> {
          use #(tail, rest) <- c.then(bit_segments(rest, value))
          Ok(#([segment, ..tail], rest))
        }
        [l.Token(l.Symbol(">>"), _), ..rest] -> Ok(#([segment], rest))
        _ -> error(rest, "Expected ',' or '>>' in bit array")
      }
    }
  }
}

fn bit_options(tokens: Tokens) -> Parsed(List(a.BitOption)) {
  use #(option, rest) <- c.then(case tokens {
    [l.Token(l.Number(n), _), ..rest] -> Ok(#(a.BitSize(n), rest))
    [
      l.Token(l.Word("size"), _),
      l.Token(l.Symbol("("), _),
      l.Token(l.Number(n), _),
      l.Token(l.Symbol(")"), _),
      ..rest
    ] -> Ok(#(a.BitSize(n), rest))
    [l.Token(l.Word(name), _), ..rest] -> Ok(#(a.BitName(name), rest))
    _ -> error(tokens, "Bit-array option requires a name or static size")
  })
  case rest {
    [l.Token(l.Symbol("-"), _), ..rest] -> {
      use #(tail, rest) <- c.then(bit_options(rest))
      Ok(#([option, ..tail], rest))
    }
    _ -> Ok(#([option], rest))
  }
}

fn import_path(tokens: Tokens) -> Parsed(List(String)) {
  use #(part, rest) <- c.then(name(tokens))
  case rest {
    [l.Token(l.Symbol("/"), _), ..rest] -> {
      use #(tail, rest) <- c.then(import_path(rest))
      Ok(#([part, ..tail], rest))
    }
    _ -> Ok(#([part], rest))
  }
}

fn last_path(parts: List(String)) -> Result(#(String, Nil), String) {
  case parts {
    [last] -> Ok(#(last, Nil))
    [_, ..rest] -> last_path(rest)
    [] -> Error("Empty module path")
  }
}

fn string_binding(tokens: Tokens) -> Parsed(a.Pattern) {
  use #(id, rest) <- c.then(name(tokens))
  case c.uppercase_name(id), c.discarded_name(id) {
    True, _ -> error(tokens, "String prefix requires a variable or discard")
    _, True -> Ok(#(a.DiscardPattern, rest))
    _, False -> Ok(#(a.VariablePattern(id), rest))
  }
}
