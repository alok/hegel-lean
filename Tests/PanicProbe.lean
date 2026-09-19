import Hegel

open Hegel Hegel.Property

/-- The test harness runs this in a subprocess and requires a nonzero exit. -/
def main : IO Unit := check! "panic-must-not-pass" (do
  let xs ← draw (Gen.list (pure (0 : Nat)) 0 0)
  let _ := xs[0]!
  assertThat (xs[0]! == 0) "unchecked-index") { database := none, maxExamples := 1 }
