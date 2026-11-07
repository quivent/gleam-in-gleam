import native/check
import native/core
import native/elf
import native/lexer
import native/parser
import native/x64

pub fn compile(source: BitArray) -> Result(BitArray, String) {
  use tokens <- core.then(lexer.lex(source))
  use ast <- core.then(parser.parse(tokens))
  use typed <- core.then(check.module(ast))
  use machine_code <- core.then(x64.generate(typed))
  Ok(elf.executable(machine_code))
}
