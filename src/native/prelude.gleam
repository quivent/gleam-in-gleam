// Reserved names cannot be written as source identifiers/module paths. Local
// declarations shadow implicit prelude names before resolution reaches these.
import native/ast as a

pub fn result_name() -> String {
  "Result@$prelude"
}

pub fn ok_name() -> String {
  "Ok@$prelude"
}

pub fn error_name() -> String {
  "Error@$prelude"
}

pub fn result_type() -> a.CustomType {
  a.CustomType(
    result_name(),
    [
      a.Variant(ok_name(), [a.FieldDefinition("", a.VariableType("a"))]),
      a.Variant(error_name(), [a.FieldDefinition("", a.VariableType("e"))]),
    ],
    True,
    ["a", "e"],
  )
}
