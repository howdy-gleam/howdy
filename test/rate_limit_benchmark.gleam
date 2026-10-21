//// Run with `gleam run -m rate_limit_benchmark`.
//// Reports median insertion time and BEAM reductions for 1k–8k unique keys.

@external(erlang, "rate_limit_test_ffi", "cardinality_benchmark")
pub fn main() -> Nil
