# Compiler constraints

This project is Jay's Gleam-in-Gleam compiler rewrite. Preserve these constraints:

* Zero third-party dependencies in the compiler. No stdlib package, parser
  package, LLVM, Cranelift, external assembler/linker, bundled VM or libc.
* Compiler logic belongs in Gleam. Bootstrap host IO must stay small and explicit.
* Do not hide compilation in foreign strings, invoke the upstream compiler from
  the compiler pipeline, bundle Node as a "native" result or claim self-hosting
  before the compiler actually recompiles itself.
* Bootstrap/dev/oracle tooling is separate from delivered native dependencies.
* Generated runtime support must be owned source with tested semantics.
* Keep unsupported language features explicit. Do not silently accept programs
  with incorrect semantics or treat subset tests as full conformance.
* Never replace the installed Crew compiler, active sessions or unrelated work.
* Use upstream as an independent semantic oracle. Retain failures and evidence.

Read README.md for current limits and stage-1/stage-2 acceptance.
