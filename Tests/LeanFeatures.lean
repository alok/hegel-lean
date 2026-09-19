import Hegel
import Tests.Registered

namespace Tests.LeanFeatures
open Hegel

inductive Color where
  | red | green | blue
  deriving Repr, BEq, Arbitrary

structure Packet (α : Type) where
  payload : α
  enabled : Bool
  deriving Repr, Arbitrary

inductive Tree where
  | leaf (value : Nat)
  | node (left right : Tree)
  deriving Repr, Arbitrary

def Tree.depth : Tree → Nat
  | .leaf _ => 0
  | .node left right => 1 + max left.depth right.depth

inductive Rose where
  | node (children : List Rose)
  deriving Repr, Arbitrary

structure Bounded where
  n : Nat
  i : Fin (n + 1)
  bound : i.val ≤ n
  deriving Repr, Arbitrary

structure Filtered where
  n : Nat
  large : 5 ≤ n
  deriving Repr, Arbitrary

-- These are kernel proofs about generated data, not testing claims.
example (x : Bounded) : x.i.val ≤ x.n := x.bound
example (x : {n : Nat // n % 2 = 0}) : x.val % 2 = 0 := x.property

private def require (b : Bool) (msg : String) : IO Unit :=
  unless b do throw (IO.userError msg)

private def settings : Settings :=
  { seed := some 42, maxExamples := 100, database := none }

private def passes (name : String) (p : Property Unit) : IO Unit := do
  let r ← check name p settings
  require r.isSuccess r.render
  IO.println s!"ok: Lean integration {name}"

private def fails (name : String) (p : Property Unit) : IO Report := do
  let r ← check name p settings
  require (r.outcome == .failed && !r.failures.isEmpty) r.render
  for f in r.failures do
    let again ← replay f.blob p settings
    require (again.status == .failed && again.origin == f.origin &&
      again.annotations == f.annotations) s!"Replay changed Lean-generated data: {reprStr again}"
  IO.println s!"ok: Lean integration {name} shrank and replayed"
  return r

private def registered : Array Test := hegel_suite% in Tests.Registered

@[hegel_test] def localProperty : Property Unit := property% true

private def allRegistered : Array Test := hegel_suite%

private def customNaturals : Property Unit :=
  letI : Arbitrary Nat := ⟨fun size => Gen.nat 1000 (1000 + size)⟩
  property% (size := 50) (fun n : Nat => decide (1000 ≤ n ∧ n ≤ 1050))

def run : IO Unit := do
  passes "local instance customization" customNaturals
  passes "sized builtins" do
    assertEq! (← forAll! (arbitrary (α := Nat) 0)) 0
    assertEq! (← forAll! (arbitrary (α := List Nat) 0)) []
    let value ← forAll! (arbitrary (α := Packet (List Nat)) 10)
    assertProp! (value.payload.length ≤ 10 ∧ value.payload.all (· ≤ 10))
    let vector ← forAll! (arbitrary (α := Vector Bool 7))
    assertProp! (vector.size = 7)
    let nested ← forAll! (arbitrary (α := Array (List Nat)) 30)
    assertProp! ((nested.toList.map List.length).sum ≤ 30)
  let colors ← samples 100 (arbitrary (α := Color)) settings
  require (colors.toList.eraseDups.length == 3) s!"Enum lost a constructor: {reprStr colors}"
  passes "recursive derivation size bounds" do
    for size in [:6] do
      let tree ← forAll! (arbitrary (α := Tree) size)
      assertProp! (tree.depth ≤ size)
    let .node children ← forAll! (arbitrary (α := Rose) 0)
    assertEq! children.length 0
    let _ ← forAll! (arbitrary (α := Rose) 3)
  passes "default recursive budget" do
    let tree ← forAll! (arbitrary (α := Tree))
    assertProp! (tree.depth ≤ 30)
    let _ ← forAll! (arbitrary (α := Rose))
  passes "dependent fields and proof fields" do
    let value ← forAll! (arbitrary (α := Bounded) 20)
    assertProp! (value.i.val ≤ value.n)
    let pair ← forAll! (Gen.sigma (Gen.nat 0 10) (fun n => Gen.vector Gen.bool n))
    assertProp! (pair.2.size = pair.1)
    let positive ← forAll! (Gen.natRange 1000 2000)
    assertProp! (1000 ≤ positive.val ∧ positive.val ≤ 2000)
    let negative ← forAll! (Gen.intRange (-2^100) (-2^90))
    assertProp! (-2^100 ≤ negative.val ∧ negative.val ≤ -2^90)
  passes "decidable propositions" do
    Property.forAllProp (arbitrary (α := List Nat) 12)
      (fun xs => xs.reverse.reverse = xs) hegelSource%
  let impossible ← check "empty Fin" (property% (fun _ : Fin 0 => true)) settings
  require (impossible.outcome == .error) "Fin 0 was counted as a passing campaign"
  let impossibleSubtype ← check "empty subtype" (do
    let _ ← Property.draw (Gen.subtype (fun _ : Nat => False) (pure 0))) settings
  require (impossibleSubtype.outcome == .error) "An impossible subtype was counted as passing"
  let constrained : Gen {n : Nat // n % 2 = 0} := Gen.subtype (· % 2 = 0) (Gen.nat 0 100)
  let shrunk ← fails "proof-carrying shrink" do
    let n ← forAll! constrained
    assertProp! (n.val < 6)
  require (shrunk.failures[0]!.annotations.any (· == "6")) shrunk.render
  let derived ← fails "derived proof field shrink" do
    let value ← forAll! (arbitrary (α := Filtered) 30)
    assertProp! (value.n < 10)
  require (derived.failures[0]!.annotations.any (·.contains "n := 10")) derived.render
  let functions ← fails "generated function arguments" <|
    property% (size := 30) (fun n : Nat => decide (n < 5))
  require (functions.failures[0]!.annotations == #["5"]) functions.render
  require (functions.failures[0]!.origin.startsWith "assertion at Tests.LeanFeatures:")
    s!"Missing stable source origin: {functions.render}"
  require (registered.size == 3 && allRegistered.size == 4)
    "Registration lost imported or local declarations"
  require (registered.map (·.name) == #["registered configuration",
    "Tests.Registered.dependentIndex", "Tests.Registered.reverseTwice"])
    "Registration changed declaration ordering or configured names"
  require (registered[0]?.any fun t => t.settings.maxExamples == 10 && t.settings.seed == some 42)
    "Registration lost explicit settings"
  for test in registered do
    let r ← check test.name test.property { test.settings with database := none, seed := some 42 }
    require r.isSuccess r.render
  IO.println "ok: imported/local registration, stable order and per-test settings"

end Tests.LeanFeatures
