// Qualified production CLI bounds. Diagnostic builds pass their limits explicitly.
// Ordinary generated programs retain the separate 64 MiB arena contract.
pub fn source_capacity() -> Int {
  131_072
}

pub fn arena_capacity() -> Int {
  536_870_912
}
