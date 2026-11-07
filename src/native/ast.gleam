pub type Type {
  Integer
  Boolean
  Unit
  StringType
  BitArrayType
  TupleType(List(Type))
  ListType(Type)
  QualifiedType(String, String, List(Type))
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
  BitArrayLiteral(List(BitSegment(Expression)))
  TupleIndex(Expression, Int)
  FieldAccess(Expression, String)
  ModuleFallbackField(Expression, String, Result(String, String))
  Variable(String)
  Unary(String, Expression)
  Binary(String, Expression, Expression)
  Call(String, List(Argument))
  Apply(Expression, List(Argument))
  RecordUpdate(String, Expression, List(Argument))
  QualifiedRecordUpdate(String, String, Expression, List(Argument))
  Lambda(List(LambdaParameter), Annotation, List(Statement))
  Block(List(Statement))
  Case(Expression, List(Arm))
  CaseSubjects(List(Expression), List(MultiArm))
  Echo(Expression)
}

pub type LambdaParameter {
  LambdaParameter(pattern: Pattern, annotation: Annotation)
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
  AliasPattern(Pattern, String)
  BitArrayPattern(List(BitSegment(Pattern)))
  CheckedBitArrayPattern(List(#(Pattern, BitMode)))
  StringPattern(BitArray)
  StringPrefixPattern(BitArray, Pattern, Pattern)
  IntegerPattern(Int)
  BooleanPattern(Bool)
  DiscardPattern
  VariablePattern(String)
  TuplePattern(List(Pattern))
  ListPattern(List(Pattern), PatternRest)
  ModuleConstructorPattern(String, String, List(PatternField), Bool)
  ConstructorPattern(String, List(PatternField), Bool)
  // Checker-produced constructor identity and field types, never parser output.
  CheckedConstructorPattern(Int, List(#(Pattern, Type)))
}

pub type PatternRest {
  NoPatternRest
  RestPattern(Pattern)
}

pub type Arm {
  Arm(pattern: Pattern, guard: Guard(Expression), body: Expression)
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
  Module(
    functions: List(Function),
    custom_types: List(CustomType),
    imports: List(Import),
    aliases: List(TypeAlias),
  )
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

pub type BitSegment(t) {
  BitSegment(value: t, options: List(BitOption))
}

pub type BitOption {
  BitName(String)
  BitSize(Int)
}

pub type BitMode {
  IntegerSegment(bytes: Int, little: Bool, signed: Bool)
  BitsSegment
  BytesSegment
  Utf8Segment
}

pub type Import {
  Import(module_name: String, alias: String)
}

pub type TypeAlias {
  TypeAlias(name: String, parameters: List(String), value: Type, public_: Bool)
}

pub type Guard(t) {
  NoGuard
  Guard(t)
}

pub type MultiArm {
  MultiArm(
    alternatives: List(List(Pattern)),
    guard: Guard(Expression),
    body: Expression,
  )
}

// Outer aliases bind values but do not change matching or coverage.
pub fn without_alias(pattern: Pattern) -> Pattern {
  case pattern {
    AliasPattern(inner, _) -> without_alias(inner)
    _ -> pattern
  }
}
