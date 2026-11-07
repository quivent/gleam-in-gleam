fn twice(f: fn(a) -> a, x: a) -> a {
  f(f(x))
}

fn increment(x: Int) -> Int {
  x + 1
}

type Handler(a, b) {
  Handler(run: fn(a) -> b)
}

fn invoke(handler: Handler(a, b), x: a) -> b {
  handler.run(x)
}

pub fn main() -> Nil {
  echo twice(increment, 20)
  let handler = Handler(increment)
  echo invoke(handler, 2)
  let f = increment
  echo f(3)
  Nil
}
