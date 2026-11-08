// Stage-0 build entry for the owned native CLI. This is not runtime host IO.
import native/check
import native/core as c
import native/elf
import native/project
import native/x64

pub fn build(sources: List(project.Source)) -> Result(BitArray, String) {
  use #(ast, globals) <- c.then(project.link_with_context("native/cli", sources))
  use typed <- c.then(check.module_with_context(ast, globals))
  use code <- c.then(x64.generate_cli(typed, globals))
  Ok(elf.executable(code))
}
