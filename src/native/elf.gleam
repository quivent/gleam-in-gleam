import native/core

// A Linux x86-64 ET_EXEC with one read/execute LOAD and a non-executable stack.
// No dynamic loader, shared library, assembler or linker is invoked.
pub fn executable(code: BitArray) -> BitArray {
  let header_size = 64 + 56 * 2
  let file_size = header_size + core.byte_length(code)
  let base = 4_194_304
  let entry = base + header_size
  let ident = <<127, 69, 76, 70, 2, 1, 1, 0, 0:64>>
  let header = <<
    ident:bits,
    2:16-little,
    62:16-little,
    1:32-little,
    entry:64-little,
    64:64-little,
    0:64-little,
    0:32-little,
    64:16-little,
    56:16-little,
    2:16-little,
    0:16-little,
    0:16-little,
    0:16-little,
  >>
  let load = <<
    1:32-little,
    5:32-little,
    0:64-little,
    base:64-little,
    base:64-little,
    file_size:64-little,
    file_size:64-little,
    4096:64-little,
  >>
  let stack = <<
    1_685_382_481:32-little,
    6:32-little,
    0:64-little,
    0:64-little,
    0:64-little,
    0:64-little,
    0:64-little,
    16:64-little,
  >>
  <<header:bits, load:bits, stack:bits, code:bits>>
}
