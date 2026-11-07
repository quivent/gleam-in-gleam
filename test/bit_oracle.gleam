pub fn byte_count(data: BitArray) -> Int {
  case data {
    <<>> -> 0
    <<_, rest:bits>> -> 1 + byte_count(rest)
    _ -> -1
  }
}

pub fn byte_sum(data: BitArray) -> Int {
  case data {
    <<>> -> 0
    <<n, rest:bits>> -> n + byte_sum(rest)
    _ -> -1
  }
}

pub fn bit_empty() -> Int {
  byte_count(<<>>)
}

pub fn bit_default(n: Int) -> Int {
  byte_sum(<<n, -1, { n + 256 }>>)
}

pub fn bit_little(n: Int) -> Int {
  case <<n:16-little, { n + 2 }:24-little, { n + 3 }:32-little>> {
    <<a:16-little, b:24-little, c:32-little>> -> a + b + c
    _ -> 0
  }
}

pub fn bit_big(n: Int) -> Int {
  case <<n:16, { n + 2 }:24, { n + 3 }:32>> {
    <<a:16, b:24, c:32>> -> a + b + c
    _ -> 0
  }
}

pub fn bit_endian(n: Int) -> Int {
  let data = <<n:16-little>>
  case data {
    <<a:16-big>> -> a
    _ -> 0
  }
}

pub fn bit_48(n: Int) -> Int {
  case <<n:48-little, { n + 1 }:48-big>> {
    <<a:48-little, b:48-big>> -> a + b
    _ -> 0
  }
}

pub fn bit_signed(n: Int) -> Int {
  case <<n, n:16-little, n:24-big, n:32-little>> {
    <<a:signed, b:16-little-signed, c:24-big-signed, d:32-little-signed>> ->
      a + b + c + d
    _ -> 0
  }
}

pub fn bit_concat(n: Int) -> Int {
  let a = <<n, { n + 1 }>>
  let b = <<{ n + 2 }>>
  let data = <<9, a:bits, b:bits, a:bits, 10>>
  byte_sum(data) + byte_count(data)
}

fn returned_tail(n: Int) -> BitArray {
  case <<1, n, { n + 1 }>> {
    <<_, tail:bytes>> -> tail
    _ -> <<>>
  }
}

pub fn bit_tail_return(n: Int) -> Int {
  let data = returned_tail(n)
  byte_sum(data) + byte_count(data)
}

pub fn bit_capture(n: Int) -> Int {
  let data = returned_tail(n)
  let f = fn(x: Int) { byte_sum(<<data:bits, x>>) }
  f(n + 2)
}

pub fn bit_zero(n: Int) -> Int {
  byte_sum(<<n:0, 3, n:0>>) + byte_count(<<n:0>>)
}

pub fn bit_options(n: Int) -> Int {
  case <<n:int-size(16)-little>> {
    <<a:unsigned-little-int-size(16)>> -> a
    _ -> 0
  }
}

pub fn bit_literal(n: Int) -> Int {
  case <<n>> {
    <<1>> -> 10
    <<2>> -> 20
    _ -> 30
  }
}

pub fn bit_lengths(n: Int) -> Int {
  let data = <<n, { n + 1 }>>
  case data {
    <<_>> -> 1
    <<_, _, _>> -> 3
    <<a, b>> -> a + b
    _ -> 0
  }
}

pub fn bit_full_tail(n: Int) -> Int {
  let data = <<n, { n + 1 }>>
  let <<tail:bits>> = data
  byte_sum(tail)
}

type BitBox(a) {
  BitBox(value: a, marker: Int)
}

pub fn bit_record(n: Int) -> Int {
  let box = BitBox(<<n, { n + 1 }>>, 3)
  let updated = BitBox(..box, marker: 5)
  byte_sum(updated.value) + updated.marker
}
