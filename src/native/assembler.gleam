import native/core as c

pub type Part {
  Bytes(BitArray)
  Label(String)
  Relative(opcode: BitArray, target: String)
  // Ordered immutable instruction span; no bytes or labels are copied to join it.
  Span(List(Part))
}

// Preserve small prefixes directly; retain longer already-planned sequences.
pub fn join(left: List(Part), right: List(Part)) -> List(Part) {
  case right {
    [] -> left
    _ ->
      case left {
        [] -> right
        [first] -> [first, ..right]
        [first, second] -> [first, second, ..right]
        _ -> [Span(left), ..right]
      }
  }
}

// Fuse instruction layout, relocation capture and label indexing. The second
// walk visits only output chunks, in reverse order, and builds their final order.
// No second instruction/span walk or repeated byte-length measurement is needed.
type Chunk {
  Literal(BitArray)
  Fixup(opcode: BitArray, target: String, hash: Int, next: Int)
}

// Immutable AVL index by owned bounded hash. Collisions retain full label names;
// a hash match never stands in for string equality.
type Index {
  Empty
  Tree(
    height: Int,
    hash: Int,
    entries: List(#(String, Int)),
    left: Index,
    right: Index,
  )
}

pub fn assemble(parts: List(Part)) -> Result(BitArray, String) {
  use #(labels, chunks) <- c.then(layout(parts, 0, Empty, [], []))
  use chunks <- c.then(resolve(chunks, labels, [], ""))
  Ok(c.concat(chunks))
}

// Development traces retain the historical reverse-declaration symbol order.
// Reuse the same validating layout rather than maintaining another assembler.
pub fn symbols(parts: List(Part)) -> Result(List(#(String, Int)), String) {
  use #(labels, _) <- c.then(layout(parts, 0, Empty, [], []))
  symbol_order(parts, labels, [], [])
}

fn name_hash(bytes: BitArray, hash: Int) -> Int {
  case bytes {
    <<first, rest:bits>> ->
      name_hash(rest, { hash * 33 + first } % 2_147_483_647)
    _ -> hash
  }
}

fn height(index: Index) -> Int {
  case index {
    Empty -> 0
    Tree(h, _, _, _, _) -> h
  }
}

fn node(
  hash: Int,
  entries: List(#(String, Int)),
  left: Index,
  right: Index,
) -> Index {
  let lh = height(left)
  let rh = height(right)
  let h = case lh > rh {
    True -> lh + 1
    False -> rh + 1
  }
  Tree(h, hash, entries, left, right)
}

fn balance(
  hash: Int,
  entries: List(#(String, Int)),
  left: Index,
  right: Index,
) -> Index {
  case height(left) - height(right) {
    n if n > 1 ->
      case left {
        Tree(_, lh, le, ll, lr) ->
          case height(ll) >= height(lr) {
            True -> node(lh, le, ll, node(hash, entries, lr, right))
            False ->
              case lr {
                Tree(_, mh, me, ml, mr) ->
                  node(
                    mh,
                    me,
                    node(lh, le, ll, ml),
                    node(hash, entries, mr, right),
                  )
                Empty -> node(hash, entries, left, right)
              }
          }
        Empty -> node(hash, entries, left, right)
      }
    n if n < -1 ->
      case right {
        Tree(_, rh, re, rl, rr) ->
          case height(rr) >= height(rl) {
            True -> node(rh, re, node(hash, entries, left, rl), rr)
            False ->
              case rl {
                Tree(_, mh, me, ml, mr) ->
                  node(
                    mh,
                    me,
                    node(hash, entries, left, ml),
                    node(rh, re, mr, rr),
                  )
                Empty -> node(hash, entries, left, right)
              }
          }
        Empty -> node(hash, entries, left, right)
      }
    _ -> node(hash, entries, left, right)
  }
}

fn insert(
  index: Index,
  hash: Int,
  name: String,
  offset: Int,
) -> Result(Index, String) {
  case index {
    Empty -> Ok(Tree(1, hash, [#(name, offset)], Empty, Empty))
    Tree(_, key, entries, left, right) ->
      case hash == key {
        True ->
          case c.lookup(entries, name) {
            Ok(_) -> Error("Duplicate assembly label: " <> name)
            Error(_) -> Ok(node(key, [#(name, offset), ..entries], left, right))
          }
        False ->
          case hash < key {
            True -> {
              use left <- c.then(insert(left, hash, name, offset))
              Ok(balance(key, entries, left, right))
            }
            False -> {
              use right <- c.then(insert(right, hash, name, offset))
              Ok(balance(key, entries, left, right))
            }
          }
      }
  }
}

fn lookup(index: Index, hash: Int, name: String) -> Result(Int, String) {
  case index {
    Empty -> Error("Unknown name: " <> name)
    Tree(_, key, entries, left, right) ->
      case hash == key {
        True -> c.lookup(entries, name)
        False ->
          case hash < key {
            True -> lookup(left, hash, name)
            False -> lookup(right, hash, name)
          }
      }
  }
}

fn layout(
  parts: List(Part),
  offset: Int,
  labels: Index,
  chunks: List(Chunk),
  pending: List(List(Part)),
) -> Result(#(Index, List(Chunk)), String) {
  case parts {
    [] ->
      case pending {
        [] -> Ok(#(labels, chunks))
        [next, ..tail] -> layout(next, offset, labels, chunks, tail)
      }
    [Span(inner), ..rest] ->
      layout(inner, offset, labels, chunks, [rest, ..pending])
    [Label(name), ..rest] ->
      case insert(labels, name_hash(<<name:utf8>>, 5381), name, offset) {
        Error(e) -> Error(e)
        Ok(labels) -> layout(rest, offset, labels, chunks, pending)
      }
    [Bytes(bytes), ..rest] ->
      layout(
        rest,
        offset + c.byte_length(bytes),
        labels,
        [Literal(bytes), ..chunks],
        pending,
      )
    [Relative(opcode, name), ..rest] -> {
      let next = offset + c.byte_length(opcode) + 4
      layout(
        rest,
        next,
        labels,
        [Fixup(opcode, name, name_hash(<<name:utf8>>, 5381), next), ..chunks],
        pending,
      )
    }
  }
}

// Walking reversed chunks avoids an output reversal. Keep the earliest error
// in original instruction order, even when several relocations are invalid.
fn resolve(
  chunks: List(Chunk),
  labels: Index,
  forward: List(BitArray),
  failure: String,
) -> Result(List(BitArray), String) {
  case chunks {
    [] ->
      case failure {
        "" -> Ok(forward)
        _ -> Error(failure)
      }
    [Literal(bytes), ..rest] ->
      resolve(rest, labels, [bytes, ..forward], failure)
    [Fixup(opcode, name, hash, next), ..rest] ->
      case lookup(labels, hash, name) {
        Error(e) -> resolve(rest, labels, forward, e)
        Ok(target) -> {
          let displacement = target - next
          case displacement < -2_147_483_648 || displacement > 2_147_483_647 {
            True ->
              resolve(
                rest,
                labels,
                forward,
                "Relative relocation out of signed 32-bit range",
              )
            False ->
              resolve(
                rest,
                labels,
                [<<opcode:bits, displacement:32-little>>, ..forward],
                failure,
              )
          }
        }
      }
  }
}

fn symbol_order(
  parts: List(Part),
  labels: Index,
  reversed: List(#(String, Int)),
  pending: List(List(Part)),
) -> Result(List(#(String, Int)), String) {
  case parts {
    [] ->
      case pending {
        [] -> Ok(reversed)
        [next, ..tail] -> symbol_order(next, labels, reversed, tail)
      }
    [Span(inner), ..rest] ->
      symbol_order(inner, labels, reversed, [rest, ..pending])
    [Label(name), ..rest] -> {
      case lookup(labels, name_hash(<<name:utf8>>, 5381), name) {
        Error(e) -> Error(e)
        Ok(offset) ->
          symbol_order(rest, labels, [#(name, offset), ..reversed], pending)
      }
    }
    [_, ..rest] -> symbol_order(rest, labels, reversed, pending)
  }
}
