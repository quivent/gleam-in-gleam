// Pure project loading/resolution. Host bridges provide named source bytes only;
// imports, dependency order, namespaces and visibility are compiler policy.
import native/ast as a
import native/core as c
import native/definitions as d
import native/free_names
import native/lexer
import native/parser
import native/prelude
import native/type_system as types

pub type Source {
  Source(name: String, content: BitArray)
}

type Loaded {
  Loaded(name: String, module_: a.Module)
}

type Scope {
  Scope(current: Loaded, entry: String, modules: List(Loaded))
}

pub fn dependencies(source: BitArray) -> Result(List(String), String) {
  use tokens <- c.then(lexer.lex(source))
  use module_ <- c.then(parser.parse(tokens))
  use _ <- c.then(validate_imports(module_.imports, []))
  Ok(c.map(module_.imports, fn(i) { i.module_name }))
}

pub fn link(entry: String, sources: List(Source)) -> Result(a.Module, String) {
  use _ <- c.then(valid_name(entry))
  use index <- c.then(source_index(sources, []))
  use modules <- c.then(visit(entry, index, [], []))
  use resolved <- c.then(
    c.try_map(modules, fn(m) { resolve_module(Scope(m, entry, modules)) }),
  )
  let linked =
    a.Module(
      flatten(c.map(resolved, fn(m) { m.functions })),
      flatten(c.map(resolved, fn(m) { m.custom_types })),
      [],
      [],
    )
  use context <- c.then(d.collect(linked))
  use _ <- c.then(
    c.try_map(modules, fn(m) {
      c.try_map(m.module_.aliases, fn(alias) {
        use body <- c.then(expand_alias(alias, Scope(m, entry, modules), []))
        use _ <- c.then(d.validate_type(
          body,
          d.Context(..context, function_parameters: alias.parameters),
        ))
        let used = types.variables([body])
        c.try_map(alias.parameters, fn(n) {
          case local(used, n) {
            True -> Ok(Nil)
            False -> Error("Unused type alias parameter: " <> n)
          }
        })
      })
    }),
  )
  Ok(linked)
}

fn source_index(
  sources: List(Source),
  acc: List(#(String, BitArray)),
) -> Result(List(#(String, BitArray)), String) {
  case sources {
    [] -> Ok(acc)
    [source, ..rest] -> {
      use _ <- c.then(valid_name(source.name))
      use _ <- c.then(case c.lookup(acc, source.name) {
        Ok(_) -> Error("Duplicate module source: " <> source.name)
        Error(_) -> Ok(Nil)
      })
      source_index(rest, [#(source.name, source.content), ..acc])
    }
  }
}

fn visit(
  name: String,
  sources: List(#(String, BitArray)),
  active: List(#(String, Nil)),
  done: List(Loaded),
) -> Result(List(Loaded), String) {
  case c.lookup(c.map(done, fn(m) { #(m.name, m) }), name) {
    Ok(_) -> Ok(done)
    Error(_) -> {
      use _ <- c.then(case c.lookup(active, name) {
        Ok(_) -> Error("Import cycle at module: " <> name)
        Error(_) -> Ok(Nil)
      })
      use source <- c.then(case c.lookup(sources, name) {
        Ok(source) -> Ok(source)
        Error(_) -> Error("Missing module source: " <> name)
      })
      use tokens <- c.then(lexer.lex(source))
      use module_ <- c.then(parser.parse(tokens))
      use _ <- c.then(validate_imports(module_.imports, []))
      use _ <- c.then(alias_headers(module_))
      use done <- c.then(visit_imports(
        module_.imports,
        sources,
        [#(name, Nil), ..active],
        done,
      ))
      Ok(c.append(done, [Loaded(name, module_)]))
    }
  }
}

fn visit_imports(
  imports: List(a.Import),
  sources: List(#(String, BitArray)),
  active: List(#(String, Nil)),
  done: List(Loaded),
) -> Result(List(Loaded), String) {
  case imports {
    [] -> Ok(done)
    [i, ..rest] -> {
      use done <- c.then(visit(i.module_name, sources, active, done))
      visit_imports(rest, sources, active, done)
    }
  }
}

fn validate_imports(
  imports: List(a.Import),
  aliases: List(#(String, Nil)),
) -> Result(Nil, String) {
  case imports {
    [] -> Ok(Nil)
    [i, ..rest] -> {
      use _ <- c.then(valid_name(i.module_name))
      use _ <- c.then(case valid_part(<<i.alias:utf8>>, True) {
        True -> Ok(Nil)
        False -> Error("Invalid/unsupported module alias: " <> i.alias)
      })
      use _ <- c.then(case c.lookup(aliases, i.alias) {
        Ok(_) -> Error("Duplicate module alias: " <> i.alias)
        Error(_) -> Ok(Nil)
      })
      validate_imports(rest, [#(i.alias, Nil), ..aliases])
    }
  }
}

fn valid_name(name: String) -> Result(Nil, String) {
  case valid_path(<<name:utf8>>, True) {
    True -> Ok(Nil)
    False -> Error("Invalid module name: " <> name)
  }
}

fn valid_path(bytes: BitArray, first: Bool) -> Bool {
  case bytes {
    <<>> -> !first
    <<47, rest:bits>> if !first -> valid_path(rest, True)
    <<n, rest:bits>> if n >= 97 && n <= 122 -> valid_path(rest, False)
    <<n, rest:bits>> if !first && { n >= 48 && n <= 57 || n == 95 } ->
      valid_path(rest, False)
    _ -> False
  }
}

fn valid_part(bytes: BitArray, first: Bool) -> Bool {
  case bytes {
    <<>> -> !first
    <<n, rest:bits>> if n >= 97 && n <= 122 -> valid_part(rest, False)
    <<n, rest:bits>> if !first && { n >= 48 && n <= 57 || n == 95 } ->
      valid_part(rest, False)
    _ -> False
  }
}

fn flatten(lists: List(List(t))) -> List(t) {
  case lists {
    [] -> []
    [first, ..rest] -> c.append(first, flatten(rest))
  }
}

fn internal(name: String, module_name: String, entry: String) -> String {
  case module_name == entry {
    True -> name
    False -> name <> "@" <> module_name
  }
}

fn module_by_name(name: String, scope: Scope) -> Result(Loaded, String) {
  c.lookup(c.map(scope.modules, fn(m) { #(m.name, m) }), name)
}

fn imported(alias: String, scope: Scope) -> Result(Loaded, String) {
  use i <- c.then(
    case
      c.lookup(
        c.map(scope.current.module_.imports, fn(i) { #(i.alias, i) }),
        alias,
      )
    {
      Ok(i) -> Ok(i)
      Error(_) -> Error("Unknown module alias: " <> alias)
    },
  )
  module_by_name(i.module_name, scope)
}

fn local(bound: List(String), name: String) -> Bool {
  case c.lookup(c.map(bound, fn(n) { #(n, Nil) }), name) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn is_module(
  alias: String,
  member: String,
  bound: List(String),
  scope: Scope,
) -> Bool {
  case local(bound, alias) && !c.uppercase_name(member) {
    True -> False
    False ->
      case imported(alias, scope) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

fn value_in(
  name: String,
  m: Loaded,
  external: Bool,
  entry: String,
) -> Result(String, String) {
  let functions = c.map(m.module_.functions, fn(f) { #(f.name, f.public_) })
  let constructors =
    flatten(
      c.map(m.module_.custom_types, fn(t) {
        c.map(t.variants, fn(v) { #(v.name, t.public_) })
      }),
    )
  case c.lookup(c.append(functions, constructors), name) {
    Ok(public_) ->
      case external && !public_ {
        True -> Error("Private module member: " <> m.name <> "." <> name)
        False -> Ok(internal(name, m.name, entry))
      }
    Error(_) ->
      case external, name {
        False, "Ok" -> Ok(prelude.ok_name())
        False, "Error" -> Ok(prelude.error_name())
        _, _ -> Error("Unknown name: " <> m.name <> "." <> name)
      }
  }
}

fn qualified_value(
  alias: String,
  name: String,
  scope: Scope,
) -> Result(String, String) {
  use m <- c.then(imported(alias, scope))
  value_in(name, m, True, scope.entry)
}

fn value(
  name: String,
  bound: List(String),
  scope: Scope,
) -> Result(String, String) {
  case local(bound, name) {
    True -> Ok(name)
    False -> value_in(name, scope.current, False, scope.entry)
  }
}

fn named_type(
  name: String,
  args: List(a.Type),
  m: Loaded,
  external: Bool,
  scope: Scope,
  active: List(#(String, Nil)),
) -> Result(a.Type, String) {
  case c.lookup(c.map(m.module_.aliases, fn(t) { #(t.name, t) }), name) {
    Ok(alias) -> {
      use _ <- c.then(case external && !alias.public_ {
        True -> Error("Private module type: " <> m.name <> "." <> name)
        False -> Ok(Nil)
      })
      use body <- c.then(expand_alias(alias, Scope(..scope, current: m), active))
      use bindings <- c.then(types.bindings(alias.parameters, args))
      types.substitute(body, bindings)
    }
    Error(_) -> {
      use t <- c.then(
        case
          c.lookup(c.map(m.module_.custom_types, fn(t) { #(t.name, t) }), name)
        {
          Ok(t) -> Ok(t)
          Error(_) ->
            case name == "Result" && !external {
              True -> Ok(prelude.result_type())
              False -> Error("Unknown type: " <> m.name <> "." <> name)
            }
        },
      )
      case external && !t.public_ {
        True -> Error("Private module type: " <> m.name <> "." <> name)
        False ->
          Ok(types.apply(
            case t.name == prelude.result_name() {
              True -> prelude.result_name()
              False -> internal(name, m.name, scope.entry)
            },
            args,
          ))
      }
    }
  }
}

fn type_(t: a.Type, scope: Scope) -> Result(a.Type, String) {
  type_with(t, scope, [])
}

fn type_with(
  t: a.Type,
  scope: Scope,
  active: List(#(String, Nil)),
) -> Result(a.Type, String) {
  case t {
    a.QualifiedType(alias, name, args) -> {
      use m <- c.then(imported(alias, scope))
      use args <- c.then(c.try_map(args, fn(t) { type_with(t, scope, active) }))
      named_type(name, args, m, True, scope, active)
    }
    a.NamedType(name) ->
      named_type(name, [], scope.current, False, scope, active)
    a.AppliedType(name, args) -> {
      use args <- c.then(c.try_map(args, fn(t) { type_with(t, scope, active) }))
      named_type(name, args, scope.current, False, scope, active)
    }
    a.TupleType(ts) -> {
      use ts <- c.then(c.try_map(ts, fn(t) { type_with(t, scope, active) }))
      Ok(a.TupleType(ts))
    }
    a.ListType(t) -> {
      use t <- c.then(type_with(t, scope, active))
      Ok(a.ListType(t))
    }
    a.FunctionType(params, result) -> {
      use params <- c.then(
        c.try_map(params, fn(t) { type_with(t, scope, active) }),
      )
      use result <- c.then(type_with(result, scope, active))
      Ok(a.FunctionType(params, result))
    }
    _ -> Ok(t)
  }
}

fn expand_alias(
  alias: a.TypeAlias,
  scope: Scope,
  active: List(#(String, Nil)),
) -> Result(a.Type, String) {
  let key = scope.current.name <> "." <> alias.name
  use _ <- c.then(case c.lookup(active, key) {
    Ok(_) -> Error("Type alias cycle: " <> key)
    Error(_) -> Ok(Nil)
  })
  type_with(alias.value, scope, [#(key, Nil), ..active])
}

fn annotation(t: a.Annotation, scope: Scope) -> Result(a.Annotation, String) {
  case t {
    a.Inferred -> Ok(t)
    a.Annotated(t) -> {
      use t <- c.then(type_(t, scope))
      Ok(a.Annotated(t))
    }
  }
}

fn resolve_module(scope: Scope) -> Result(a.Module, String) {
  use types <- c.then(
    c.try_map(scope.current.module_.custom_types, fn(t) {
      use _ <- c.then(case t.name {
        "Int" | "Bool" | "Nil" | "String" | "List" | "BitArray" ->
          Error("Builtin type shadowing is not implemented: " <> t.name)
        _ -> Ok(Nil)
      })
      use variants <- c.then(
        c.try_map(t.variants, fn(v) {
          use _ <- c.then(case v.name {
            "True" | "False" | "Nil" ->
              Error(
                "Builtin constructor shadowing is not implemented: " <> v.name,
              )
            _ -> Ok(Nil)
          })
          use fields <- c.then(
            c.try_map(v.fields, fn(f) {
              use type_ <- c.then(type_(f.type_, scope))
              Ok(a.FieldDefinition(..f, type_: type_))
            }),
          )
          Ok(a.Variant(
            internal(v.name, scope.current.name, scope.entry),
            fields,
          ))
        }),
      )
      Ok(
        a.CustomType(
          ..t,
          name: internal(t.name, scope.current.name, scope.entry),
          variants: variants,
        ),
      )
    }),
  )
  use functions <- c.then(
    c.try_map(scope.current.module_.functions, fn(f) {
      use parameters <- c.then(
        c.try_map(f.parameters, fn(p) {
          use t <- c.then(type_(p.1, scope))
          Ok(#(p.0, t))
        }),
      )
      use result <- c.then(type_(f.result, scope))
      use body <- c.then(statements(
        f.body,
        c.map(f.parameters, fn(p) { p.0 }),
        scope,
      ))
      Ok(
        a.Function(
          ..f,
          name: internal(f.name, scope.current.name, scope.entry),
          parameters: parameters,
          result: result,
          body: body,
        ),
      )
    }),
  )
  Ok(a.Module(functions, types, [], []))
}

fn statements(
  body: List(a.Statement),
  bound: List(String),
  scope: Scope,
) -> Result(List(a.Statement), String) {
  case body {
    [] -> Ok([])
    [a.Evaluate(e), ..rest] -> {
      use e <- c.then(expression(e, bound, scope))
      use tail <- c.then(statements(rest, bound, scope))
      Ok([a.Evaluate(e), ..tail])
    }
    [a.Bind(p, t, e), ..rest] -> {
      use e <- c.then(expression(e, bound, scope))
      use p <- c.then(pattern(p, scope))
      use t <- c.then(annotation(t, scope))
      use tail <- c.then(statements(
        rest,
        c.append(free_names.pattern_names(p), bound),
        scope,
      ))
      Ok([a.Bind(p, t, e), ..tail])
    }
  }
}

fn arguments(
  args: List(a.Argument),
  bound: List(String),
  scope: Scope,
) -> Result(List(a.Argument), String) {
  c.try_map(args, fn(arg) {
    use e <- c.then(expression(arg.value, bound, scope))
    Ok(a.Argument(..arg, value: e))
  })
}

fn expression(
  e: a.Expression,
  bound: List(String),
  scope: Scope,
) -> Result(a.Expression, String) {
  case e {
    a.Variable(name) -> {
      use _ <- c.then(case c.discarded_name(name) {
        True -> Error("Discarded variable cannot be read")
        False -> Ok(Nil)
      })
      use name <- c.then(value(name, bound, scope))
      Ok(a.Variable(name))
    }
    a.Call(name, args) -> {
      use name <- c.then(value(name, bound, scope))
      use args <- c.then(arguments(args, bound, scope))
      Ok(a.Call(name, args))
    }
    a.FieldAccess(a.Variable(alias), member) -> {
      case is_module(alias, member, bound, scope) {
        True -> {
          use name <- c.then(qualified_value(alias, member, scope))
          Ok(a.Variable(name))
        }
        False -> {
          use target <- c.then(expression(a.Variable(alias), bound, scope))
          case imported(alias, scope) {
            Ok(_) ->
              Ok(a.ModuleFallbackField(
                target,
                member,
                qualified_value(alias, member, scope),
              ))
            Error(_) -> Ok(a.FieldAccess(target, member))
          }
        }
      }
    }
    a.FieldAccess(target, field) -> {
      use target <- c.then(expression(target, bound, scope))
      Ok(a.FieldAccess(target, field))
    }
    a.Apply(a.FieldAccess(a.Variable(alias), member), args) -> {
      use args <- c.then(arguments(args, bound, scope))
      case is_module(alias, member, bound, scope) {
        True -> {
          use name <- c.then(qualified_value(alias, member, scope))
          Ok(a.Call(name, args))
        }
        False -> {
          use target <- c.then(expression(
            a.FieldAccess(a.Variable(alias), member),
            bound,
            scope,
          ))
          Ok(a.Apply(target, args))
        }
      }
    }
    a.Apply(target, args) -> {
      use target <- c.then(expression(target, bound, scope))
      use args <- c.then(arguments(args, bound, scope))
      Ok(a.Apply(target, args))
    }
    a.RecordUpdate(name, target, args) -> {
      use name <- c.then(value_in(name, scope.current, False, scope.entry))
      use target <- c.then(expression(target, bound, scope))
      use args <- c.then(arguments(args, bound, scope))
      Ok(a.RecordUpdate(name, target, args))
    }
    a.QualifiedRecordUpdate(alias, member, target, args) -> {
      use name <- c.then(qualified_value(alias, member, scope))
      use target <- c.then(expression(target, bound, scope))
      use args <- c.then(arguments(args, bound, scope))
      Ok(a.RecordUpdate(name, target, args))
    }
    a.TupleLiteral(es) -> {
      use es <- c.then(c.try_map(es, fn(e) { expression(e, bound, scope) }))
      Ok(a.TupleLiteral(es))
    }
    a.ListLiteral(es, tail) -> {
      use es <- c.then(c.try_map(es, fn(e) { expression(e, bound, scope) }))
      use tail <- c.then(case tail {
        a.NoRest -> Ok(a.NoRest)
        a.Rest(e) -> {
          use e <- c.then(expression(e, bound, scope))
          Ok(a.Rest(e))
        }
      })
      Ok(a.ListLiteral(es, tail))
    }
    a.BitArrayLiteral(segments) -> {
      use segments <- c.then(
        c.try_map(segments, fn(s) {
          use e <- c.then(expression(s.value, bound, scope))
          Ok(a.BitSegment(..s, value: e))
        }),
      )
      Ok(a.BitArrayLiteral(segments))
    }
    a.TupleIndex(target, index) -> {
      use target <- c.then(expression(target, bound, scope))
      Ok(a.TupleIndex(target, index))
    }
    a.Unary(op, e) -> {
      use e <- c.then(expression(e, bound, scope))
      Ok(a.Unary(op, e))
    }
    a.Binary(op, l, r) -> {
      use l <- c.then(expression(l, bound, scope))
      use r <- c.then(expression(r, bound, scope))
      Ok(a.Binary(op, l, r))
    }
    a.Echo(e) -> {
      use e <- c.then(expression(e, bound, scope))
      Ok(a.Echo(e))
    }
    a.Block(body) -> {
      use body <- c.then(statements(body, bound, scope))
      Ok(a.Block(body))
    }
    a.Lambda(params, result, body) -> {
      use params <- c.then(
        c.try_map(params, fn(p) {
          use pat <- c.then(pattern(p.pattern, scope))
          use t <- c.then(annotation(p.annotation, scope))
          Ok(a.LambdaParameter(pat, t))
        }),
      )
      use result <- c.then(annotation(result, scope))
      let names =
        flatten(c.map(params, fn(p) { free_names.pattern_names(p.pattern) }))
      use body <- c.then(statements(body, c.append(names, bound), scope))
      Ok(a.Lambda(params, result, body))
    }
    a.CaseSubjects(subjects, arms) -> {
      use subjects <- c.then(
        c.try_map(subjects, fn(e) { expression(e, bound, scope) }),
      )
      use arms <- c.then(
        c.try_map(arms, fn(arm) {
          use alternatives <- c.then(
            c.try_map(arm.alternatives, fn(row) {
              c.try_map(row, fn(p) { pattern(p, scope) })
            }),
          )
          let names = case alternatives {
            [first, ..] -> flatten(c.map(first, free_names.pattern_names))
            _ -> []
          }
          let branch_bound = c.append(names, bound)
          use body <- c.then(expression(arm.body, branch_bound, scope))
          use guard <- c.then(case arm.guard {
            a.NoGuard -> Ok(a.NoGuard)
            a.Guard(e) -> {
              use e <- c.then(expression(e, branch_bound, scope))
              Ok(a.Guard(e))
            }
          })
          Ok(a.MultiArm(alternatives, guard, body))
        }),
      )
      Ok(a.CaseSubjects(subjects, arms))
    }
    a.Case(subject, arms) -> {
      use subject <- c.then(expression(subject, bound, scope))
      use arms <- c.then(
        c.try_map(arms, fn(arm) {
          use p <- c.then(pattern(arm.pattern, scope))
          use body <- c.then(expression(
            arm.body,
            c.append(free_names.pattern_names(p), bound),
            scope,
          ))
          use guard <- c.then(case arm.guard {
            a.NoGuard -> Ok(a.NoGuard)
            a.Guard(e) -> {
              use e <- c.then(expression(
                e,
                c.append(free_names.pattern_names(p), bound),
                scope,
              ))
              Ok(a.Guard(e))
            }
          })
          Ok(a.Arm(p, guard, body))
        }),
      )
      Ok(a.Case(subject, arms))
    }
    _ -> Ok(e)
  }
}

fn pattern(p: a.Pattern, scope: Scope) -> Result(a.Pattern, String) {
  case p {
    a.ConstructorPattern(name, fields, spread) -> {
      use name <- c.then(value_in(name, scope.current, False, scope.entry))
      use fields <- c.then(pattern_fields(fields, scope))
      Ok(a.ConstructorPattern(name, fields, spread))
    }
    a.ModuleConstructorPattern(alias, member, fields, spread) -> {
      use name <- c.then(qualified_value(alias, member, scope))
      use fields <- c.then(pattern_fields(fields, scope))
      Ok(a.ConstructorPattern(name, fields, spread))
    }
    a.TuplePattern(ps) -> {
      use ps <- c.then(c.try_map(ps, fn(p) { pattern(p, scope) }))
      Ok(a.TuplePattern(ps))
    }
    a.ListPattern(ps, tail) -> {
      use ps <- c.then(c.try_map(ps, fn(p) { pattern(p, scope) }))
      use tail <- c.then(case tail {
        a.NoPatternRest -> Ok(a.NoPatternRest)
        a.RestPattern(p) -> {
          use p <- c.then(pattern(p, scope))
          Ok(a.RestPattern(p))
        }
      })
      Ok(a.ListPattern(ps, tail))
    }
    a.BitArrayPattern(segments) -> {
      use segments <- c.then(
        c.try_map(segments, fn(s) {
          use p <- c.then(pattern(s.value, scope))
          Ok(a.BitSegment(..s, value: p))
        }),
      )
      Ok(a.BitArrayPattern(segments))
    }
    a.CheckedConstructorPattern(_, _) | a.CheckedBitArrayPattern(_) ->
      Error("Checked pattern in source project")
    _ -> Ok(p)
  }
}

fn pattern_fields(
  fields: List(a.PatternField),
  scope: Scope,
) -> Result(List(a.PatternField), String) {
  c.try_map(fields, fn(f) {
    use p <- c.then(pattern(f.pattern, scope))
    Ok(a.PatternField(..f, pattern: p))
  })
}

fn alias_headers(module_: a.Module) -> Result(Nil, String) {
  use _ <- c.then(
    unique_type_names(
      c.append(
        c.map(module_.custom_types, fn(t) { t.name }),
        c.map(module_.aliases, fn(t) { t.name }),
      ),
      [],
    ),
  )
  use _ <- c.then(
    c.try_map(module_.aliases, fn(alias) {
      use _ <- c.then(case c.uppercase_name(alias.name) {
        True -> Ok(Nil)
        False -> Error("Type names must start with uppercase: " <> alias.name)
      })
      case alias.name {
        "Int" | "Bool" | "Nil" | "String" | "List" | "BitArray" ->
          Error("Builtin type shadowing is not implemented: " <> alias.name)
        _ -> alias_parameters(alias.parameters, [])
      }
    }),
  )
  Ok(Nil)
}

fn unique_type_names(
  names: List(String),
  seen: List(String),
) -> Result(Nil, String) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case local(seen, name) {
        True -> Error("Duplicate type: " <> name)
        False -> unique_type_names(rest, [name, ..seen])
      }
  }
}

fn alias_parameters(
  names: List(String),
  seen: List(String),
) -> Result(Nil, String) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case c.uppercase_name(name) || c.discarded_name(name), local(seen, name) {
        True, _ -> Error("Type parameters must be named lowercase variables")
        _, True -> Error("Duplicate type parameter: " <> name)
        _, _ -> alias_parameters(rest, [name, ..seen])
      }
  }
}
