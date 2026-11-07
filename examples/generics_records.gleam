type Maybe(a) {
  None
  Some(a)
}

type Envelope(a) {
  Envelope(payload: a, count: Int)
}

fn number(value: Maybe(Int)) -> Int {
  case value {
    None -> 0
    Some(n) -> n
  }
}

pub fn main() -> Nil {
  let envelope = Envelope(count: echo 2, payload: Some(echo 21))
  let Envelope(payload: value, ..) = envelope
  echo number(value)
  echo envelope.count
  Nil
}
