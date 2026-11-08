// Stage-0 build entry for the owned native CLI. This is not runtime host IO.
import native/check
import native/core as c
import native/definitions
import native/elf
import native/project
import native/x64

pub fn build(sources: List(project.Source)) -> Result(BitArray, String) {
  use ast <- c.then(project.link("native/cli", sources))
  use typed <- c.then(check.module(ast))
  use globals <- c.then(definitions.collect(ast))
  use code <- c.then(x64.generate_cli(typed, globals))
  Ok(elf.executable(code))
}
