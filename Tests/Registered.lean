import Hegel

namespace Tests.Registered
open Hegel

@[hegel_test] def reverseTwice : Property Unit :=
  property% (fun xs : List Nat => xs.reverse.reverse == xs)

@[hegel_test] def dependentIndex : Property Unit :=
  property% (size := 12) (fun (n : Nat) (i : Fin (n + 1)) => decide (i.val ≤ n))

@[hegel_test] def configured : Test := {
  name := "registered configuration"
  property := property% (fun b : Bool => b == !(!b))
  settings := { seed := some 42, maxExamples := 10, database := none }
}

end Tests.Registered
