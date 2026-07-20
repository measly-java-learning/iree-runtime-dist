// Canonical smoke module. Entry point @add: (4xf32, 4xf32) -> 4xf32, elementwise.
// Shipped precompiled by the paired compiler so a consumer can prove "the runtime
// loads and runs a known module" without installing a compiler.
func.func @add(%lhs: tensor<4xf32>, %rhs: tensor<4xf32>) -> tensor<4xf32> {
  %result = arith.addf %lhs, %rhs : tensor<4xf32>
  return %result : tensor<4xf32>
}
