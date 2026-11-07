// Type-directed x86-64 helpers. ABI: RCX=left, RAX=right; result Bool in RAX.
// Equality allocates no heap memory. Recursive lists walk tails in a loop.
import native/assembler as asm
import native/core as c
import native/equality as e

fn raw(bytes: BitArray) -> asm.Part {
  asm.Bytes(bytes)
}

fn branch(op: Int, target: String) -> asm.Part {
  asm.Relative(<<15, op:8>>, target)
}

fn jump(target: String) -> asm.Part {
  asm.Relative(<<233>>, target)
}

fn call(target: String) -> asm.Part {
  asm.Relative(<<232>>, target)
}

pub fn label(plan: Int, entry: Int) -> String {
  "rt:eq:" <> c.decimal(plan) <> ":" <> c.decimal(entry)
}

pub fn uses_strings(plan: e.Plan) -> Bool {
  any_text(plan.entries)
}

fn any_text(entries: List(e.Entry)) -> Bool {
  case entries {
    [] -> False
    [e.Entry(_, _, e.Text), ..] -> True
    [_, ..rest] -> any_text(rest)
  }
}

pub fn generate(plan: e.Plan, id: Int) -> Result(List(asm.Part), String) {
  use parts <- c.then(c.try_map(plan.entries, fn(entry) { helper(entry, id) }))
  flatten(parts)
}

fn flatten(parts: List(List(asm.Part))) -> Result(List(asm.Part), String) {
  case parts {
    [] -> Ok([])
    [first, ..rest] -> {
      use rest <- c.then(flatten(rest))
      Ok(c.append(first, rest))
    }
  }
}

fn enter(name: String) -> List(asm.Part) {
  [
    asm.Label(name),
    raw(<<
      85,
      72,
      137,
      229,
      72,
      131,
      236,
      16,
      72,
      137,
      77,
      248,
      72,
      137,
      69,
      240,
    >>),
  ]
}

fn guards(name: String) -> List(asm.Part) {
  [
    raw(<<72, 57, 200>>),
    branch(132, name <> vr_true()),
    raw(<<72, 133, 192>>),
    branch(132, name <> vr_false()),
    raw(<<72, 133, 201>>),
    branch(132, name <> vr_false()),
  ]
}

fn vr_true() -> String {
  ":true"
}

fn vr_false() -> String {
  ":false"
}

fn finish(name: String) -> List(asm.Part) {
  [
    asm.Label(name <> vr_true()),
    raw(<<184, 1, 0, 0, 0, 201, 195>>),
    asm.Label(name <> vr_false()),
    raw(<<49, 192, 201, 195>>),
  ]
}

fn fields(
  ids: List(Int),
  index: Int,
  plan: Int,
  failure: String,
) -> List(asm.Part) {
  case ids {
    [] -> []
    [id, ..rest] -> {
      let offset = 16 + index * 8
      [
        raw(<<
          72,
          139,
          77,
          248,
          72,
          139,
          69,
          240,
          72,
          139,
          137,
          offset:32-little,
          72,
          139,
          128,
          offset:32-little,
        >>),
        call(label(plan, id)),
        raw(<<72, 133, 192>>),
        branch(132, failure),
        ..fields(rest, index + 1, plan, failure)
      ]
    }
  }
}

fn helper(entry: e.Entry, plan: Int) -> Result(List(asm.Part), String) {
  let name = label(plan, entry.id)
  case entry.shape {
    e.Pending -> Error("Incomplete equality shape reached native emission")
    e.Uninhabited -> Ok([asm.Label(name), jump("rt:match")])
    e.Word ->
      Ok([
        asm.Label(name),
        raw(<<72, 57, 200, 15, 148, 192, 72, 15, 182, 192, 195>>),
      ])
    e.Text -> Ok([asm.Label(name), jump("rt:string_equal")])
    e.Bits -> Ok(bits(name))
    e.Tuple(ids) ->
      Ok(c.append(
        enter(name),
        c.append(guards(name), [
          raw(<<72, 131, 120, 8, 1>>),
          branch(133, "rt:match"),
          raw(<<72, 131, 121, 8, 1>>),
          branch(133, "rt:match"),
          ..c.append(fields(ids, 0, plan, name <> vr_false()), finish(name))
        ]),
      ))
    e.ListOf(child) ->
      Ok(
        c.append(enter(name), [
          asm.Label(name <> ":loop"),
          raw(<<72, 139, 77, 248, 72, 139, 69, 240>>),
          ..c.append(guards(name), [
            raw(<<72, 131, 120, 8, 2>>),
            branch(133, "rt:match"),
            raw(<<72, 131, 121, 8, 2>>),
            branch(133, "rt:match"),
            // Save both next pointers before comparing heads; no live scratch
            // register is trusted across a child helper call.
            raw(<<
              72,
              139,
              80,
              24,
              72,
              137,
              85,
              240,
              72,
              139,
              81,
              24,
              72,
              137,
              85,
              248,
            >>),
            raw(<<72, 139, 81, 16, 72, 139, 64, 16, 72, 137, 209>>),
            call(label(plan, child)),
            raw(<<72, 133, 192>>),
            branch(132, name <> vr_false()),
            jump(name <> ":loop"),
            ..finish(name)
          ])
        ]),
      )
    e.Nominal(variants) ->
      Ok(c.append(
        enter(name),
        c.append(guards(name), [
          raw(<<72, 139, 81, 8, 72, 59, 80, 8>>),
          branch(133, name <> vr_false()),
          ..c.append(
            dispatch(variants, name),
            c.append(variant_fields(variants, plan, name), finish(name)),
          )
        ]),
      ))
  }
}

fn dispatch(variants: List(e.Variant), name: String) -> List(asm.Part) {
  case variants {
    [] -> [jump("rt:match")]
    [variant, ..rest] -> [
      raw(<<72, 129, 250, variant.tag:32-little>>),
      branch(132, name <> ":tag:" <> c.decimal(variant.tag)),
      ..dispatch(rest, name)
    ]
  }
}

fn variant_fields(
  variants: List(e.Variant),
  plan: Int,
  name: String,
) -> List(asm.Part) {
  case variants {
    [] -> []
    [variant, ..rest] -> [
      asm.Label(name <> ":tag:" <> c.decimal(variant.tag)),
      ..c.append(fields(variant.fields, 0, plan, name <> vr_false()), [
        jump(name <> vr_true()),
        ..variant_fields(rest, plan, name)
      ])
    ]
  }
}

fn bits(name: String) -> List(asm.Part) {
  [
    asm.Label(name),
    raw(<<72, 137, 207, 72, 137, 198, 72, 139, 79, 16, 72, 59, 78, 16>>),
    branch(133, name <> vr_false()),
    raw(<<72, 133, 201>>),
    branch(132, name <> vr_true()),
    raw(<<
      72,
      139,
      127,
      24,
      72,
      139,
      118,
      24,
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
    asm.Label(name <> vr_false()),
    raw(<<49, 192, 195>>),
    asm.Label(name <> vr_true()),
    raw(<<184, 1, 0, 0, 0, 195>>),
  ]
}
