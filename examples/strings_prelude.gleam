fn produce(n: Int) -> Result(String, String) {
  case n {
    0 -> Error("missing")
    _ -> Ok("prefix:" <> "λ😀")
  }
}

pub fn main() -> Nil {
  case produce(1) {
    Ok(text) -> {
      echo text == "prefix:λ😀"
      case text {
        "prefix:" as head <> tail -> {
          echo head <> tail == text
          echo tail
          Nil
        }
        _ -> Nil
      }
    }
    Error(error) -> {
      echo error
      Nil
    }
  }
  case <<"λ":utf8>> {
    <<a, b>> -> {
      echo a
      echo b
      Nil
    }
    _ -> Nil
  }
  Nil
}
