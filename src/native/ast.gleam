pub type Type {
  Integer
  Boolean
  Unit
  StringType
  TupleType(List(Type))
  ListType(Type)
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
  Variable(String)
  Unary(String, Expression)
  Binary(String, Expression, Expression)
  Call(String, List(Expression))
  Block(List(Statement))
  Case(Expression, List(Arm))
  Echo(Expression)
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
  )
}

pub type Module {
  Module(functions: List(Function))
}
