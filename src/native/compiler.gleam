import native/check
import native/core
import native/definitions
import native/elf
import native/project
import native/x64

pub fn compile(source: BitArray) -> Result(BitArray, String) {
  compile_project("main", [project.Source("main", source)])
}

pub fn dependencies(source: BitArray) -> Result(List(String), String) {
  project.dependencies(source)
}

pub fn compile_project(
  entry: String,
  sources: List(project.Source),
) -> Result(BitArray, String) {
  use ast <- core.then(project.link(entry, sources))
  use typed <- core.then(check.module(ast))
  use globals <- core.then(definitions.collect(ast))
  use machine_code <- core.then(x64.generate_with(typed, globals))
  Ok(elf.executable(machine_code))
}
