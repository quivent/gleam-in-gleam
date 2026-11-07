pub type Type {
  Integer
  Boolean
  Unit
  StringType
  TupleType(List(Type))
  ListType(Type)
  NamedType(String)
  AppliedType(String, List(Type))
  VariableType(String)
  FunctionType(List(Type), Type)
  // Internal placeholder for an empty list; never a source type annotation.
  Unresolved
}

pub type Annotation {
  Inferred
  Annotated(Type)
}

pub type Expression {
  IntegerLiteral(Int)
  BooleanLiteral(Bool)
  UnitLiteral
  StringLiteral(BitArray)
  TupleLiteral(List(Expression))
  ListLiteral(List(Expression), ListRest)
  TupleIndex(Expression, Int)
  FieldAccess(Expression, String)
  Variable(String)
  Unary(String, Expression)
  Binary(String, Expression, Expression)
  Call(String, List(Argument))
  Apply(Expression, List(Argument))
  Block(List(Statement))
  Case(Expression, List(Arm))
  Echo(Expression)
}

pub type Argument {
  Argument(label: String, value: Expression)
}

pub type PatternField {
  PatternField(label: String, pattern: Pattern)
}

pub type ListRest {
  NoRest
  Rest(Expression)
}

pub type Statement {
  Bind(Pattern, Annotation, Expression)
  Evaluate(Expression)
}

pub type Pattern {
  IntegerPattern(Int)
  BooleanPattern(Bool)
  DiscardPattern
  VariablePattern(String)
  TuplePattern(List(Pattern))
  ListPattern(List(Pattern), PatternRest)
  ConstructorPattern(String, List(PatternField), Bool)
  // Checker-produced constructor identity and field types, never parser output.
  CheckedConstructorPattern(Int, List(#(Pattern, Type)))
}

pub type PatternRest {
  NoPatternRest
  RestPattern(Pattern)
}

pub type Arm {
  Arm(pattern: Pattern, body: Expression)
}

pub type Function {
  Function(
    name: String,
    parameters: List(#(String, Type)),
    result: Type,
    body: List(Statement),
    public_: Bool,
  )
}

pub type Module {
  Module(functions: List(Function), custom_types: List(CustomType))
}

pub type CustomType {
  CustomType(
    name: String,
    variants: List(Variant),
    public_: Bool,
    parameters: List(String),
  )
}

pub type Variant {
  Variant(name: String, fields: List(FieldDefinition))
}

pub type FieldDefinition {
  FieldDefinition(label: String, type_: Type)
}
