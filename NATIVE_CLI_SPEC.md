# Native CLI milestone

Status: bounded implementation qualified in 59 targeted tests; full regression
receipt in evidence/native-cli-verification.json. Target: standalone Linux x86-64, no Node,
libc, external compiler, assembler, linker or VM at runtime.

## Command

```text
gleam-native SOURCE.gleam NEW_OUTPUT [--source-root DIRECTORY]
gleam-native --help
gleam-native --version
```

SOURCE is a relative module path beneath DIRECTORY (default current directory).
For example, `gleam-native modules.gleam out/app --source-root examples` loads
`examples/modules.gleam` and its imports. This root-relative source convention
is explicit; the existing bootstrap bridge's default dirname convention is kept.
Module names retain the existing lowercase/digit/underscore path rules.

Exit codes: 0 success/help/version; 1 source/compiler/output failure; 2 invalid
arguments. Existing owned runtime overflow/arena failures remain 70/71.

## Boundary

A pure Gleam state machine returns typed requests: Arguments, ReadSource,
WriteExecutable and Finish. Its callbacks receive ordinary Result values.
An explicit native entrypoint interprets these requests through owned emitted
instructions. No placeholder function overrides or hidden upstream compilation.
The runtime validates the actual constructor/function ABI before emitting code.

ReadSource uses a root directory descriptor and openat2 resolution beneath it,
rejecting symlinks/magic links and traversal. Accept regular files only, with a
16 KiB per-file bound; detect size changes during reading. Limit argv to 256 user
arguments and 4095 bytes each, validating scalar UTF-8 before forming Strings.
Cap the source graph at 256 files. The initial 1 MiB proposal was reduced after a 33 KiB comment-only input
exposed native frontend stack exhaustion. These bounds are explicit, not full-size reliability
or full upstream compatibility claims. Unsupported syscalls fail explicitly.

Output is written to an exclusive sibling temporary file, with complete-write
loops, mode 0755, file fsync and checked close. Publish through renameat2 with
RENAME_NOREPLACE. Clean up the owned temporary file on normal IO errors. Existing
output files and symlinks remain untouched. Directory crash durability and cleanup
after process termination are not promised by this milestone.

Retry interrupted read/write/open/stat/chmod/fsync/rename operations. Do not retry
Linux close after an error. Diagnostics go to stderr; help/version to stdout.

## Acceptance

* Real single-file and imported-module compilation from a native executable;
  resulting bytes match bootstrap output and emitted programs run correctly.
* Empty PATH execution, actual ELF header inspection, no external process calls.
* Help/version/usage; invalid source/UTF-8; missing files/imports, cycles; directory,
  FIFO and oversized input; traversal/symlink refusals; Unicode root/output paths.
* Preserve existing output bytes/mode, including a symlink destination; publish
  only after a complete write; clean temporary files after ordinary failures.
* Exercise partial reads/writes, EINTR and write/publication failures through a
  bounded syscall fault-injection harness where practical; keep these observations
  distinct from normal kernel runs.
* Prior source/compiler tests and historical example bytes remain qualified.

Linux ABI references: [openat2](https://man7.org/linux/man-pages/man2/openat2.2.html),
[renameat2](https://man7.org/linux/man-pages/man2/rename.2.html),
[close](https://man7.org/linux/man-pages/man2/close.2.html), and the host Linux UAPI
headers. These are design references, not delivered dependencies.

## Qualified result

The standalone image is 582,442 bytes, SHA256
`d3428f3554f4fbce00f18e8a0fcb52cceeccd332b4e47b15e41b9580648fc39e`.
59 CLI-specific tests and the full 631-test/297-upstream-comparison run pass.
All sixteen example outputs match bootstrap bytes and execute correctly.
The actual ptrace run records 4 short reads and 54 short writes performed by the
kernel, rather than fake successful syscalls. CLI/child ELF headers and selected
instruction windows are retained in evidence/native-cli-io-verification.json and
evidence/native-cli-disassembly.txt. The earlier size failure is preserved in
evidence/native-cli-initial-size-failure.json. Full-size self-building and a native
self-build command invoking cli_builder.build remain separate work.
