// Owned Linux x86-64 effect runner. No foreign code or external assembler.
import native/assembler as asm
import native/ast as a
import native/cli_limits
import native/core as c
import native/definitions as d
import native/prelude

fn raw(bytes: BitArray) -> asm.Part {
  asm.Bytes(bytes)
}

fn label(name: String) -> asm.Part {
  asm.Label("cli:" <> name)
}

fn jump(name: String) -> asm.Part {
  asm.Relative(<<233>>, "cli:" <> name)
}

fn branch(op: Int, name: String) -> asm.Part {
  asm.Relative(<<15, op:8>>, "cli:" <> name)
}

fn call(name: String) -> asm.Part {
  asm.Relative(<<232>>, name)
}

fn addr(reg: Int, name: String) -> asm.Part {
  asm.Relative(<<72, 141, { 5 + reg * 8 }:8>>, "cli:" <> name)
}

fn ld(reg: Int, offset: Int) -> asm.Part {
  raw(<<72, 139, { 133 + reg * 8 }:8, offset:32-little>>)
}

fn st(reg: Int, offset: Int) -> asm.Part {
  raw(<<72, 137, { 133 + reg * 8 }:8, offset:32-little>>)
}

fn lea(reg: Int, offset: Int) -> asm.Part {
  raw(<<72, 141, { 133 + reg * 8 }:8, offset:32-little>>)
}

fn imm(reg: Int, value: Int) -> asm.Part {
  raw(<<72, { 184 + reg }:8, value:64-little>>)
}

fn cmp(reg: Int, value: Int) -> asm.Part {
  raw(<<72, 129, { 248 + reg }:8, value:32-little>>)
}

fn sys(number: Int) -> asm.Part {
  raw(<<184, number:32-little, 15, 5>>)
}

fn prologue(size: Int) -> asm.Part {
  raw(<<85, 72, 137, 229, 72, 129, 236, size:32-little>>)
}

fn ret() -> asm.Part {
  raw(<<201, 195>>)
}

fn constructor(
  context: d.Context,
  name: String,
  fields: List(a.Type),
  labels: List(String),
) -> Result(Int, String) {
  use value <- c.then(c.lookup(context.constructors, name))
  case
    value.owner == "Request" && value.fields == fields && value.labels == labels
  {
    True -> Ok(value.tag)
    False -> Error("Native CLI constructor ABI mismatch: " <> name)
  }
}

fn signature(
  context: d.Context,
  name: String,
  args: List(a.Type),
  result: a.Type,
) -> Result(Nil, String) {
  use f <- c.then(c.lookup(context.functions, name))
  case c.map(f.parameters, fn(p) { p.1 }) == args && f.result == result {
    True -> Ok(Nil)
    False -> Error("Native CLI function ABI mismatch: " <> name)
  }
}

pub fn generate(
  context: d.Context,
) -> Result(#(List(asm.Part), List(asm.Part)), String) {
  generate_with_limit(context, cli_limits.source_capacity())
}

// Development callers may explicitly choose a larger diagnostic bound.
// Production builds always use generate's qualified limit.
pub fn generate_with_limit(
  context: d.Context,
  source_limit: Int,
) -> Result(#(List(asm.Part), List(asm.Part)), String) {
  use _ <- c.then(case source_limit >= 16_384 && source_limit <= 1_048_576 {
    True -> Ok(Nil)
    False ->
      Error("Diagnostic source limit must be between 16384 and 1048576 bytes")
  })
  let request = a.NamedType("Request")
  let state = a.NamedType("State")
  let string = a.StringType
  let result = prelude.result_name()
  use arguments <- c.then(constructor(context, "Arguments", [], []))
  use read <- c.then(
    constructor(context, "ReadSource", [string, string, state], [
      "root",
      "path",
      "state",
    ]),
  )
  use write <- c.then(
    constructor(context, "WriteExecutable", [string, a.BitArrayType], [
      "path",
      "bytes",
    ]),
  )
  use finish <- c.then(
    constructor(context, "Finish", [a.Integer, string, a.Boolean], [
      "status",
      "message",
      "stderr",
    ]),
  )
  use _ <- c.then(signature(context, "main", [], request))
  use _ <- c.then(signature(
    context,
    "with_arguments",
    [a.ListType(string)],
    request,
  ))
  use _ <- c.then(signature(
    context,
    "with_source",
    [state, a.AppliedType(result, [a.BitArrayType, string])],
    request,
  ))
  use _ <- c.then(signature(
    context,
    "with_output",
    [string, a.AppliedType(result, [a.Unit, string])],
    request,
  ))
  use _ <- c.then(signature(
    context,
    "temporary_name",
    [string, a.Integer],
    string,
  ))
  use _ <- c.then(signature(
    context,
    "valid@native/utf8",
    [a.BitArrayType],
    a.Boolean,
  ))
  use ok <- c.then(c.lookup(context.constructors, prelude.ok_name()))
  use error <- c.then(c.lookup(context.constructors, prelude.error_name()))
  let helpers =
    c.append(
      c_string(),
      c.append(
        from_c(),
        c.append(
          argv(),
          c.append(
            read_file(source_limit),
            c.append(
              write_all(),
              c.append(
                write_file(),
                c.append(
                  result_constructor("ok", ok.tag),
                  c.append(
                    result_constructor("error", error.tag),
                    messages(source_limit),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  Ok(#(entry(arguments, read, write, finish), helpers))
}

fn entry(arguments: Int, read: Int, write: Int, finish: Int) -> List(asm.Part) {
  [
    prologue(64),
    call("rt:heap_init"),
    call("fn:main"),
    label("dispatch"),
    st(0, -16),
    raw(<<72, 139, 72, 8>>),
    cmp(1, arguments),
    branch(132, "dispatch:arguments"),
    cmp(1, read),
    branch(132, "dispatch:read"),
    cmp(1, write),
    branch(132, "dispatch:write"),
    cmp(1, finish),
    branch(132, "dispatch:finish"),
    imm(7, 70),
    sys(60),
    label("dispatch:arguments"),
    lea(7, 8),
    call("cli:argv"),
    cmp(0, 1),
    branch(132, "bad_arguments"),
    raw(<<80>>),
    call("fn:with_arguments"),
    raw(<<72, 131, 196, 8>>),
    jump("dispatch"),
    label("dispatch:read"),
    ld(0, -16),
    raw(<<72, 139, 80, 32>>),
    st(2, -24),
    raw(<<72, 139, 112, 24, 72, 139, 120, 16>>),
    call("cli:read"),
    st(0, -32),
    ld(0, -24),
    raw(<<80>>),
    ld(0, -32),
    raw(<<80>>),
    call("fn:with_source"),
    raw(<<72, 131, 196, 16>>),
    jump("dispatch"),
    label("dispatch:write"),
    ld(0, -16),
    raw(<<72, 139, 120, 16>>),
    st(7, -24),
    raw(<<72, 139, 112, 24>>),
    call("cli:write"),
    st(0, -32),
    ld(0, -24),
    raw(<<80>>),
    ld(0, -32),
    raw(<<80>>),
    call("fn:with_output"),
    raw(<<72, 131, 196, 16>>),
    jump("dispatch"),
    label("dispatch:finish"),
    ld(0, -16),
    raw(<<72, 139, 120, 16>>),
    st(7, -24),
    raw(<<72, 139, 112, 24, 72, 139, 80, 32>>),
    imm(7, 1),
    raw(<<72, 133, 210>>),
    branch(132, "finish_fd"),
    imm(7, 2),
    label("finish_fd"),
    raw(<<72, 139, 22, 72, 133, 210>>),
    branch(132, "exit"),
    raw(<<72, 131, 194, 1, 72, 131, 198, 8>>),
    call("cli:write_all"),
    cmp(0, 0),
    branch(140, "diagnostic_failure"),
    label("exit"),
    ld(7, -24),
    sys(60),
    label("diagnostic_failure"),
    imm(7, 1),
    sys(60),
    label("bad_arguments"),
    addr(6, "msg:arguments"),
    raw(<<72, 139, 22, 72, 131, 194, 1, 72, 131, 198, 8>>),
    imm(7, 2),
    call("cli:write_all"),
    imm(7, 2),
    sys(60),
  ]
}

// String -> owned NUL-terminated bytes. RDI input, RAX output; zero on length error.
fn c_string() -> List(asm.Part) {
  [
    label("c_string"),
    prologue(32),
    st(7, -8),
    raw(<<72, 139, 7>>),
    cmp(0, 4095),
    branch(135, "c_string:bad"),
    st(0, -16),
    raw(<<72, 131, 192, 24, 72, 131, 224, 248, 72, 137, 199>>),
    call("rt:allocate"),
    raw(<<72, 137, 56, 72, 199, 64, 8, 253, 255, 255, 255, 72, 131, 192, 16>>),
    st(0, -24),
    ld(6, -8),
    ld(1, -16),
    raw(<<72, 131, 198, 8, 72, 137, 199, 252, 243, 164, 198, 7, 0>>),
    ld(0, -24),
    ret(),
    label("c_string:bad"),
    imm(0, 0),
    ret(),
  ]
}

// Kernel C string -> validated owned String. Zero is failure, never a String.
fn from_c() -> List(asm.Part) {
  [
    label("from_c"),
    prologue(80),
    st(7, -8),
    imm(1, 0),
    label("from_c:scan"),
    cmp(1, 4095),
    branch(135, "from_c:bad"),
    raw(<<128, 60, 15, 0>>),
    branch(132, "from_c:validate"),
    raw(<<72, 255, 193>>),
    jump("from_c:scan"),
    label("from_c:validate"),
    st(1, -16),
    imm(0, 40),
    st(0, -64),
    imm(0, -1),
    st(0, -56),
    st(1, -48),
    st(7, -40),
    imm(0, 0),
    st(0, -32),
    lea(0, -64),
    raw(<<80>>),
    call("fn:valid@native/utf8"),
    raw(<<72, 131, 196, 8, 72, 133, 192>>),
    branch(132, "from_c:bad"),
    ld(0, -16),
    raw(<<72, 131, 192, 32, 72, 131, 224, 248, 72, 137, 199>>),
    call("rt:allocate"),
    raw(<<72, 137, 56, 72, 199, 64, 8, 254, 255, 255, 255, 72, 131, 192, 16>>),
    st(0, -24),
    ld(1, -16),
    raw(<<72, 137, 8, 72, 141, 120, 8>>),
    ld(6, -8),
    raw(<<252, 243, 164, 198, 7, 10>>),
    ld(0, -24),
    ret(),
    label("from_c:bad"),
    imm(0, 0),
    ret(),
  ]
}

fn argv() -> List(asm.Part) {
  [
    label("argv"),
    prologue(48),
    st(7, -8),
    raw(<<72, 139, 7, 72, 131, 232, 1>>),
    cmp(0, 256),
    branch(135, "argv:bad"),
    st(0, -16),
    imm(0, 0),
    st(0, -24),
    label("argv:loop"),
    ld(1, -16),
    cmp(1, 0),
    branch(142, "argv:done"),
    ld(6, -8),
    raw(<<72, 139, 124, 206, 8>>),
    call("cli:from_c"),
    cmp(0, 0),
    branch(132, "argv:bad"),
    st(0, -32),
    imm(7, 32),
    call("rt:allocate"),
    raw(<<72, 199, 0, 32, 0, 0, 0, 72, 199, 64, 8, 2, 0, 0, 0>>),
    ld(1, -32),
    ld(2, -24),
    raw(<<72, 137, 72, 16, 72, 137, 80, 24>>),
    st(0, -24),
    raw(<<72, 131, 173, 240, 255, 255, 255, 1>>),
    jump("argv:loop"),
    label("argv:done"),
    ld(0, -24),
    ret(),
    label("argv:bad"),
    imm(0, 1),
    ret(),
  ]
}

fn result_constructor(name: String, tag: Int) -> List(asm.Part) {
  [
    label("result:" <> name),
    prologue(16),
    st(7, -8),
    imm(7, 24),
    call("rt:allocate"),
    raw(<<72, 199, 0, 24, 0, 0, 0, 72, 199, 64, 8, tag:32-little>>),
    ld(1, -8),
    raw(<<72, 137, 72, 16>>),
    ret(),
  ]
}

fn read_file(source_limit: Int) -> List(asm.Part) {
  [
    label("read"),
    prologue(272),
    st(7, -72),
    st(6, -80),
    imm(0, -1),
    st(0, -24),
    st(0, -32),
    call("cli:c_string"),
    cmp(0, 0),
    branch(132, "read:path"),
    st(0, -8),
    ld(7, -80),
    call("cli:c_string"),
    cmp(0, 0),
    branch(132, "read:path"),
    st(0, -16),
    label("read:root_open"),
    imm(7, -100),
    ld(6, -8),
    imm(2, 2_686_976),
    sys(257),
    cmp(0, -4),
    branch(132, "read:root_open"),
    cmp(0, 0),
    branch(140, "read:root_error"),
    st(0, -24),
    // open_how(flags, mode, resolve); all fields initialized.
    imm(0, 657_408),
    st(0, -104),
    imm(0, 0),
    st(0, -96),
    imm(0, 14),
    st(0, -88),
    label("read:open"),
    ld(7, -24),
    ld(6, -16),
    lea(2, -104),
    raw(<<65, 186, 24, 0, 0, 0>>),
    sys(437),
    cmp(0, -4),
    branch(132, "read:open"),
    cmp(0, -38),
    branch(132, "read:unsupported"),
    cmp(0, 0),
    branch(140, "read:open_error"),
    st(0, -32),
    ld(7, -24),
    imm(0, -1),
    st(0, -24),
    sys(3),
    cmp(0, 0),
    branch(140, "read:close_error"),
    label("read:stat"),
    ld(7, -32),
    lea(6, -256),
    sys(5),
    cmp(0, -4),
    branch(132, "read:stat"),
    cmp(0, 0),
    branch(140, "read:stat_error"),
    raw(<<139, 133, 24, 255, 255, 255, 37, 0, 240, 0, 0>>),
    cmp(0, 32_768),
    branch(133, "read:regular"),
    ld(0, -208),
    cmp(0, 0),
    branch(140, "read:large"),
    cmp(0, source_limit),
    branch(135, "read:large"),
    st(0, -40),
    raw(<<72, 131, 192, 48, 72, 131, 224, 248, 72, 137, 199>>),
    call("rt:allocate"),
    st(0, -48),
    raw(<<72, 137, 56, 72, 199, 64, 8, 255, 255, 255, 255>>),
    ld(1, -40),
    raw(<<
      72,
      137,
      72,
      16,
      72,
      141,
      80,
      40,
      72,
      137,
      80,
      24,
      72,
      199,
      64,
      32,
      0,
      0,
      0,
      0,
    >>),
    imm(0, 0),
    st(0, -56),
    label("read:loop"),
    ld(0, -48),
    raw(<<72, 139, 112, 24>>),
    ld(1, -56),
    raw(<<72, 1, 206>>),
    ld(2, -40),
    raw(<<72, 131, 194, 1, 72, 41, 202>>),
    cmp(2, 4096),
    branch(134, "read:chunk"),
    imm(2, 4096),
    label("read:chunk"),
    ld(7, -32),
    sys(0),
    cmp(0, -4),
    branch(132, "read:loop"),
    cmp(0, 0),
    branch(140, "read:read_error"),
    branch(132, "read:eof"),
    raw(<<72, 1, 133, 200, 255, 255, 255>>),
    ld(0, -56),
    ld(1, -40),
    raw(<<72, 57, 200>>),
    branch(135, "read:changed"),
    jump("read:loop"),
    label("read:eof"),
    ld(0, -56),
    ld(1, -40),
    raw(<<72, 57, 200>>),
    branch(133, "read:changed"),
    ld(7, -32),
    imm(0, -1),
    st(0, -32),
    sys(3),
    cmp(0, 0),
    branch(140, "read:close_error"),
    ld(7, -48),
    call("cli:result:ok"),
    ret(),
    ..c.append(read_errors(), [
      label("read:fail"),
      st(0, -64),
      ld(7, -32),
      cmp(7, 0),
      branch(140, "read:close_root"),
      sys(3),
      label("read:close_root"),
      ld(7, -24),
      cmp(7, 0),
      branch(140, "read:return_error"),
      sys(3),
      label("read:return_error"),
      ld(7, -64),
      call("cli:result:error"),
      ret(),
    ])
  ]
}

fn read_errors() -> List(asm.Part) {
  error_labels("read", [
    "path",
    "root_error",
    "unsupported",
    "open_error",
    "close_error",
    "stat_error",
    "regular",
    "large",
    "read_error",
    "changed",
  ])
}

fn error_labels(prefix: String, names: List(String)) -> List(asm.Part) {
  case names {
    [] -> []
    [name, ..rest] -> [
      label(prefix <> ":" <> name),
      addr(0, "msg:" <> prefix <> ":" <> name),
      jump(prefix <> ":fail"),
      ..error_labels(prefix, rest)
    ]
  }
}

// RDI fd, RSI bytes, RDX length. Return 0 or negative errno; zero write is EIO.
fn write_all() -> List(asm.Part) {
  [
    label("write_all"),
    prologue(32),
    st(7, -8),
    st(6, -16),
    st(2, -24),
    label("write_all:loop"),
    ld(2, -24),
    cmp(2, 0),
    branch(132, "write_all:done"),
    cmp(2, 16_384),
    branch(134, "write_all:chunk"),
    imm(2, 16_384),
    label("write_all:chunk"),
    ld(7, -8),
    ld(6, -16),
    sys(1),
    cmp(0, -4),
    branch(132, "write_all:loop"),
    cmp(0, 0),
    branch(140, "write_all:error"),
    branch(132, "write_all:zero"),
    raw(<<72, 1, 133, 240, 255, 255, 255, 72, 41, 133, 232, 255, 255, 255>>),
    jump("write_all:loop"),
    label("write_all:done"),
    imm(0, 0),
    ret(),
    label("write_all:zero"),
    imm(0, -5),
    label("write_all:error"),
    ret(),
  ]
}

fn write_file() -> List(asm.Part) {
  [
    label("write"),
    prologue(80),
    st(7, -56),
    st(6, -32),
    imm(0, -1),
    st(0, -24),
    imm(0, 0),
    st(0, -72),
    call("cli:c_string"),
    cmp(0, 0),
    branch(132, "write:path"),
    st(0, -8),
    ld(0, -56),
    raw(<<80>>),
    sys(39),
    raw(<<80>>),
    call("fn:temporary_name"),
    raw(<<72, 131, 196, 16, 72, 137, 199>>),
    call("cli:c_string"),
    cmp(0, 0),
    branch(132, "write:path"),
    st(0, -16),
    label("write:open"),
    imm(7, -100),
    ld(6, -16),
    imm(2, 655_553),
    raw(<<65, 186, 128, 1, 0, 0>>),
    sys(257),
    cmp(0, -4),
    branch(132, "write:open"),
    cmp(0, 0),
    branch(140, "write:open_error"),
    st(0, -24),
    imm(0, 1),
    st(0, -72),
    ld(0, -32),
    raw(<<72, 139, 112, 24, 72, 139, 80, 16>>),
    ld(7, -24),
    call("cli:write_all"),
    cmp(0, 0),
    branch(140, "write:write_error"),
    label("write:chmod"),
    ld(7, -24),
    imm(6, 493),
    sys(91),
    cmp(0, -4),
    branch(132, "write:chmod"),
    cmp(0, 0),
    branch(140, "write:chmod_error"),
    label("write:sync"),
    ld(7, -24),
    sys(74),
    cmp(0, -4),
    branch(132, "write:sync"),
    cmp(0, 0),
    branch(140, "write:sync_error"),
    ld(7, -24),
    imm(0, -1),
    st(0, -24),
    sys(3),
    cmp(0, 0),
    branch(140, "write:close_error"),
    label("write:publish"),
    imm(7, -100),
    ld(6, -16),
    imm(2, -100),
    ld(0, -8),
    raw(<<73, 137, 194, 65, 184, 1, 0, 0, 0>>),
    sys(316),
    cmp(0, -4),
    branch(132, "write:publish"),
    cmp(0, 0),
    branch(140, "write:publish_error"),
    imm(7, 0),
    call("cli:result:ok"),
    ret(),
    ..c.append(
      error_labels("write", [
        "path",
        "open_error",
        "write_error",
        "chmod_error",
        "sync_error",
        "close_error",
        "publish_error",
      ]),
      [
        label("write:fail"),
        st(0, -48),
        ld(7, -24),
        cmp(7, 0),
        branch(140, "write:cleanup"),
        sys(3),
        label("write:cleanup"),
        ld(0, -72),
        cmp(0, 0),
        branch(132, "write:return_error"),
        ld(7, -16),
        sys(87),
        label("write:return_error"),
        ld(7, -48),
        call("cli:result:error"),
        ret(),
      ],
    )
  ]
}

fn messages(source_limit: Int) -> List(asm.Part) {
  let limit_message = case source_limit == cli_limits.source_capacity() {
    True ->
      "Source exceeds "
      <> c.decimal(source_limit / 1024)
      <> " KiB native CLI limit"
    False ->
      "Source exceeds diagnostic " <> c.decimal(source_limit) <> " byte limit"
  }
  message_list([
    #(
      "arguments",
      "Invalid or oversized UTF-8 argument (max 256 arguments, 4095 bytes each)",
    ),
    #("read:path", "Path exceeds 4095 bytes"),
    #("read:root_error", "Cannot open source root"),
    #("read:unsupported", "Required openat2 syscall is unavailable"),
    #(
      "read:open_error",
      "Cannot open source beneath root (symlinks are refused)",
    ),
    #("read:close_error", "Source descriptor close failed"),
    #("read:stat_error", "Cannot stat source"),
    #("read:regular", "Source is not a regular file"),
    #("read:large", limit_message),
    #("read:read_error", "Source read failed"),
    #("read:changed", "Source size changed during read"),
    #("write:path", "Output path exceeds 4095 bytes"),
    #("write:open_error", "Cannot create exclusive temporary output"),
    #("write:write_error", "Output write failed"),
    #("write:chmod_error", "Output chmod failed"),
    #("write:sync_error", "Output fsync failed"),
    #("write:close_error", "Output close failed"),
    #(
      "write:publish_error",
      "Cannot publish output without replacing an existing path",
    ),
  ])
}

fn message_list(items: List(#(String, String))) -> List(asm.Part) {
  case items {
    [] -> []
    [#(name, text), ..rest] -> [
      label("msg:" <> name),
      raw(<<{ c.byte_length(<<text:utf8>>) }:64-little, text:utf8, 10>>),
      ..message_list(rest)
    ]
  }
}
