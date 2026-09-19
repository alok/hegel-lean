import Hegel
open Hegel

namespace LeanExamples

structure IndexedValue where
  bound : Nat
  index : Fin (bound + 1)
  valid : index.val ≤ bound
  deriving Repr, Arbitrary

@[hegel_test] def reverseTwice : Property Unit :=
  property% (fun xs : List Nat => xs.reverse.reverse == xs)

@[hegel_test] def dependentData : Property Unit :=
  property% (fun value : IndexedValue => decide (value.index.val ≤ value.bound))

@[hegel_test] def evenNumbers : Property Unit := do
  let n ← forAll! (Gen.subtype (fun n : Nat => n % 2 = 0) (Gen.nat 0 100))
  -- `n.property` is a proof usable by Lean, including after shrinking and replay.
  assertProp! ((n.val + 2) % 2 = 0)

end LeanExamples

def main : IO UInt32 :=
  runTests ((hegel_suite% in LeanExamples).map fun test =>
    { test with settings := { database := none, seed := some 42 } })
