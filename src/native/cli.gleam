// Pure CLI policy. The owned native runtime interprets Request values.
import native/compiler
import native/core as c
import native/project

pub type Config {
  Config(root: String, entry: String, output: String)
}

pub type State {
  Loading(config: Config, pending: List(String), loaded: List(project.Source))
}

pub type Request {
  Arguments
  ReadSource(root: String, path: String, state: State)
  WriteExecutable(path: String, bytes: BitArray)
  Finish(status: Int, message: String, stderr: Bool)
}

pub fn main() -> Request {
  Arguments
}

pub fn usage() -> String {
  "Usage: gleam-native SOURCE.gleam NEW_OUTPUT [--source-root DIRECTORY]"
}

pub fn with_arguments(args: List(String)) -> Request {
  case args {
    ["--help"] -> Finish(0, usage(), False)
    ["--version"] ->
      Finish(0, "gleam-native 0.1.0 (Linux x86-64; experimental)", False)
    [source, output] -> configure(source, output, ".")
    [source, output, "--source-root", root] -> configure(source, output, root)
    _ -> Finish(2, usage(), True)
  }
}

fn configure(source: String, output: String, root: String) -> Request {
  case root == "" || output == "" {
    True -> Finish(2, "Source root and output must not be empty", True)
    False ->
      case entry_name(<<source:utf8>>, "", True) {
        Error(error) -> Finish(2, error, True)
        Ok(entry) -> next(Loading(Config(root, entry, output), [entry], []))
      }
  }
}

fn entry_name(
  bytes: BitArray,
  acc: String,
  first: Bool,
) -> Result(String, String) {
  case bytes {
    <<46, 103, 108, 101, 97, 109>> if !first -> Ok(acc)
    <<47, rest:bits>> if !first -> entry_name(rest, acc <> "/", True)
    <<n, rest:bits>> if n >= 97 && n <= 122 ->
      entry_name(rest, acc <> c.character(n), False)
    <<n, rest:bits>> if !first && { n >= 48 && n <= 57 || n == 95 } ->
      entry_name(rest, acc <> c.character(n), False)
    _ -> Error("Source must be a relative module path ending in .gleam")
  }
}

fn loaded(name: String, sources: List(project.Source)) -> Bool {
  case sources {
    [] -> False
    [source, ..rest] -> source.name == name || loaded(name, rest)
  }
}

fn next(state: State) -> Request {
  let Loading(config, pending, sources) = state
  case pending {
    [] ->
      case compiler.compile_project(config.entry, c.reverse(sources)) {
        Ok(bytes) -> WriteExecutable(config.output, bytes)
        Error(error) -> Finish(1, error, True)
      }
    [name, ..rest] ->
      case loaded(name, sources) {
        True -> next(Loading(config, rest, sources))
        False ->
          case c.length(sources) >= 256 {
            True -> Finish(1, "Source graph exceeds 256 files", True)
            False -> ReadSource(config.root, name <> ".gleam", state)
          }
      }
  }
}

pub fn with_source(state: State, result: Result(BitArray, String)) -> Request {
  let Loading(config, pending, sources) = state
  case pending {
    [] -> Finish(1, "Internal CLI source state mismatch", True)
    [name, ..rest] ->
      case result {
        Error(error) ->
          Finish(1, "Cannot read " <> name <> ".gleam: " <> error, True)
        Ok(content) ->
          case compiler.dependencies(content) {
            Error(error) -> Finish(1, "In " <> name <> ": " <> error, True)
            Ok(dependencies) ->
              next(
                Loading(config, c.append(dependencies, rest), [
                  project.Source(name, content),
                  ..sources
                ]),
              )
          }
      }
  }
}

pub fn with_output(path: String, result: Result(Nil, String)) -> Request {
  case result {
    Ok(_) -> Finish(0, "", False)
    Error(error) -> Finish(1, "Cannot write " <> path <> ": " <> error, True)
  }
}

pub fn temporary_name(path: String, pid: Int) -> String {
  path <> ".gleam-tmp-" <> c.decimal(pid)
}
