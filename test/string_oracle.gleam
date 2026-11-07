fn pass(s: String) -> String {
  s
}

pub fn words() -> String {
  "hello" <> " " <> "world"
}

pub fn unicode() -> String {
  "λ" <> "😀" <> "é"
}

pub fn empty_left() -> String {
  "" <> "abc"
}

pub fn empty_right() -> String {
  "abc" <> ""
}

pub fn newlines() -> String {
  "a\n" <> "b\t\"c"
}

pub fn normalization() -> Bool {
  pass("é") == pass("é")
}

pub fn equality() -> Bool {
  "a" <> "b" == "ab"
}

pub fn inequality() -> Bool {
  "a" <> "b" != "ac"
}

pub fn empty_equality() -> Bool {
  pass("") == pass("")
}

pub fn length_mismatch() -> Bool {
  pass("") == pass("x")
}

pub fn prefix(n: Int) -> String {
  let text = case n {
    0 -> "prefix:λ😀"
    _ -> "other"
  }
  case text {
    "prefix:" <> rest -> rest
    _ -> "missing"
  }
}

pub fn prefix_as() -> String {
  case pass("alphaβ") {
    "alpha" as head <> rest -> head <> ":" <> rest
    _ -> "bad"
  }
}

pub fn full_prefix() -> String {
  case pass("λ") {
    "λ" <> rest -> rest
    _ -> "bad"
  }
}

pub fn empty_prefix() -> String {
  case pass("λ😀") {
    "" <> rest -> rest
    _ -> "bad"
  }
}

pub fn guard_concat() -> String {
  case pass("abc") {
    s if s <> "d" == "abcd" -> s <> "!"
    _ -> "bad"
  }
}

fn make_tail(text: String) -> fn() -> String {
  case text {
    "pre:" <> rest -> fn() { rest }
    _ -> fn() { "bad" }
  }
}

pub fn returned_tail() -> String {
  let f = make_tail("pre:" <> "λ😀")
  let _other = "overwrite" <> "unrelated"
  f()
}

fn produce(n: Int) -> Result(String, String) {
  case n {
    0 -> Error("x")
    _ -> Ok("yes" <> "λ")
  }
}

pub fn result_string(n: Int) -> String {
  case produce(n) {
    Ok(value) -> value
    Error(error) -> "error:" <> error
  }
}
