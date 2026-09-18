import Hegel

open Hegel Hegel.Property

def reverseTwice : Property Unit := do
  let xs ← forAll (Gen.list (Gen.int (-100) 100) 0 40) "xs"
  assertEq xs.reverse.reverse xs "reverse is involutive"

def dependentInterval : Property Unit := do
  let lo ← forAll (Gen.int (-1000) 1000) "lo"
  let hi ← forAll (Gen.int lo (lo + 100)) "hi"
  assertProp (lo ≤ hi) "ordered interval"

/-- Deliberately false: Hegel shrinks this to n = 5. -/
def smallNumbers : Property Unit := do
  let n ← forAll (Gen.int 0 100) "n"
  assertThat (n < 5) "n < 5"

def main (args : List String) : IO UInt32 := do
  match args with
  | ["fail"] => runTests #[⟨"small numbers", smallNumbers, { seed := some 42 }⟩]
  | ["replay", blob] =>
    let result ← replay blob smallNumbers
    IO.println (reprStr result)
    return if result.status == .failed then 1 else 0
  | [] => runTests #[⟨"reverse twice", reverseTwice, {}⟩,
                    ⟨"dependent interval", dependentInterval, {}⟩]
  | _ =>
    IO.eprintln "Usage: hegel_examples [fail | replay BLOB]"
    return 2
