pub type Type {
  Integer
  Boolean
  Unit
  StringType
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
  Variable(String)
  Unary(String, Expression)
  Binary(String, Expression, Expression)
  Call(String, List(Expression))
  Block(List(Statement))
  Case(Expression, List(Arm))
  Echo(Expression)
}

pub type Statement {
  Bind(String, Annotation, Expression)
  Evaluate(Expression)
}

pub type Pattern {
  IntegerPattern(Int)
  BooleanPattern(Bool)
  DiscardPattern
  VariablePattern(String)
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
