import Hegel.Gen

namespace Hegel

/-- A property interleaves draws, observations, assertions, and explicit IO. -/
abbrev Property := ReaderT (Internal.Session.type × IO.Ref (Array String)) (EIO Abort)

namespace Property

/-- Draw without recording its representation. Useful for function-valued generators. -/
def draw (gen : Gen α) : Property α := fun (session, _) => gen session

def annotate (message : String) : Property Unit := fun (_, journal) => journal.modify (·.push message)

/-- Draw and retain the final counterexample's value in the failure report. -/
def forAll [Repr α] (gen : Gen α) (label : String := "value") : Property α := do
  let value ← draw gen
  annotate s!"{label} = {reprStr value}"
  return value

/-- Origins must be stable across draws so Hegel can group and shrink each bug. -/
def failure (origin : String) (message : String := "Assertion failed") : Property α :=
  throw (.failure origin message)

def assertThat (condition : Bool) (origin : String) (message : String := "Assertion failed") :
    Property Unit := unless condition do failure origin message

def assertEq [BEq α] [Repr α] (actual expected : α) (origin : String) : Property Unit :=
  assertThat (actual == expected) origin s!"Expected {reprStr expected}, got {reprStr actual}"

/-- Evaluate a decidable proposition as a test. Passing is not a proof of universal validity. -/
def assertProp (p : Prop) [Decidable p] (origin : String) : Property Unit :=
  assertThat (decide p) origin

def assume (condition : Bool) : Property Unit := draw (Gen.assume condition)

/-- Execute an effect on every replay. The caller must reset mutable state per case. -/
def io (action : IO α) (origin : String := "IO exception") : Property α := do
  match ← action.toBaseIO with
  | .ok value => return value
  | .error e => failure origin (toString e)

/-- Direct the engine toward larger finite scores. -/
def target (score : Float) (label : String := "score") : Property Unit :=
  draw (Gen.native (Internal.target · score label))

end Property
end Hegel
