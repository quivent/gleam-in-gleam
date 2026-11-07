// Owned x86-64 helpers. String values retain [byte length][UTF-8][newline].
// Dynamic allocations add [aligned allocation size][tag=-2] before that value.
import native/assembler as asm
import native/core as c

fn raw(bytes: BitArray) -> asm.Part {
  asm.Bytes(bytes)
}

fn branch(op: Int, target: String) -> asm.Part {
  asm.Relative(<<15, op:8>>, target)
}

fn call(target: String) -> asm.Part {
  asm.Relative(<<232>>, target)
}

pub fn generate(used: List(String)) -> List(asm.Part) {
  c.append(
    include(used, "equal", compare("equal", False)),
    c.append(
      include(used, "prefix", compare("prefix", True)),
      c.append(include(used, "concat", concat()), include(used, "drop", drop())),
    ),
  )
}

fn include(
  used: List(String),
  name: String,
  code: List(asm.Part),
) -> List(asm.Part) {
  case c.lookup(c.map(used, fn(n) { #(n, Nil) }), name) {
    Ok(_) -> code
    Error(_) -> []
  }
}

// RAX=subject/right, RCX=prefix/left. Compare only after validating lengths.
fn compare(name: String, prefix: Bool) -> List(asm.Part) {
  let label = "rt:string_" <> name
  let mismatch = case prefix {
    True -> 130
    False -> 133
  }
  [
    asm.Label(label),
    raw(<<72, 137, 199, 72, 137, 206, 72, 139, 14, 72, 57, 15>>),
    branch(mismatch, label <> ":false"),
    raw(<<72, 133, 201>>),
    branch(132, label <> ":true"),
    raw(<<
      72,
      131,
      199,
      8,
      72,
      131,
      198,
      8,
      252,
      243,
      166,
      15,
      148,
      192,
      72,
      15,
      182,
      192,
      195,
    >>),
    asm.Label(label <> ":false"),
    raw(<<49, 192, 195>>),
    asm.Label(label <> ":true"),
    raw(<<184, 1, 0, 0, 0, 195>>),
  ]
}

fn prologue() -> asm.Part {
  raw(<<85, 72, 137, 229, 72, 131, 236, 32>>)
}

// RAX=byte length. Frame -24=length, -32=value pointer; RDI=destination bytes.
fn allocate() -> List(asm.Part) {
  [
    raw(<<72, 137, 69, 232, 72, 131, 192, 32>>),
    branch(130, "rt:oom"),
    raw(<<72, 131, 224, 248, 72, 137, 199>>),
    call("rt:allocate"),
    raw(<<
      72,
      137,
      56,
      72,
      199,
      64,
      8,
      254,
      255,
      255,
      255,
      72,
      131,
      192,
      16,
      72,
      137,
      69,
      224,
    >>),
    raw(<<72, 139, 77, 232, 72, 137, 8, 72, 141, 120, 8>>),
  ]
}

fn finish() -> asm.Part {
  raw(<<198, 7, 10, 72, 139, 69, 224, 201, 195>>)
}

fn concat() -> List(asm.Part) {
  [
    asm.Label("rt:string_concat"),
    prologue(),
    // Save source pointers; add lengths before allocator/header alignment.
    raw(<<
      72,
      137,
      77,
      248,
      72,
      137,
      69,
      240,
      72,
      139,
      0,
      72,
      139,
      9,
      72,
      1,
      200,
    >>),
    branch(130, "rt:oom"),
    ..c.append(allocate(), [
      raw(<<72, 139, 117, 248, 72, 139, 14, 72, 131, 198, 8, 252, 243, 164>>),
      raw(<<72, 139, 117, 240, 72, 139, 14, 72, 131, 198, 8, 252, 243, 164>>),
      finish(),
    ])
  ]
}

fn drop() -> List(asm.Part) {
  [
    asm.Label("rt:string_drop"),
    prologue(),
    raw(<<72, 137, 69, 248, 72, 137, 77, 240, 72, 139, 0, 72, 41, 200>>),
    branch(130, "rt:match"),
    ..c.append(allocate(), [
      raw(<<
        72,
        139,
        117,
        248,
        72,
        131,
        198,
        8,
        72,
        3,
        117,
        240,
        72,
        139,
        77,
        232,
        252,
        243,
        164,
      >>),
      finish(),
    ])
  ]
}
