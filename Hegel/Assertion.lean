import Hegel.Property
import Hegel.Report.Types
import Lean.Elab.Term

namespace Hegel.Assertion

class MonadAssertion (m : Type → Type) where
  fail {α : Type} (payload : Payload) : m α

instance : MonadAssertion Property where
  fail payload := do
    Property.note (.failure payload.diff) payload.message payload.source
    throw (.failure payload.source.origin payload.message)

instance : MonadAssertion IO where
  fail payload := throw (IOEnvelope.encode payload)

def failureAt [MonadAssertion m] (message : String) (source : SourceLocation)
    (diff : Option Diff := none) : m α := MonadAssertion.fail { message, source, diff }

def assertAt [Monad m] [MonadAssertion m] (condition : Bool) (message : String)
    (source : SourceLocation) : m Unit :=
  unless condition do failureAt message source

def equalAt [Monad m] [MonadAssertion m] [BEq α] [Repr α] (actual expected : α)
    (source : SourceLocation) : m Unit :=
  unless actual == expected do
    failureAt "Values are not equal" source (some (diffRepr actual expected))

def notEqualAt [Monad m] [MonadAssertion m] [BEq α] [Repr α] (actual unexpected : α)
    (source : SourceLocation) : m Unit :=
  unless actual != unexpected do failureAt s!"Values are equal: {reprStr actual}" source

def propAt [Monad m] [MonadAssertion m] (proposition : Prop) [Decidable proposition]
    (source : SourceLocation) : m Unit :=
  assertAt (decide proposition) "Proposition is false" source

def forAllAt [Repr α] (gen : Gen α) (source : SourceLocation) : Property α := do
  let (value, refs) ← Property.drawWithProvenance gen
  Property.note (.drawn refs) (reprStr value) (some source)
  return value

end Hegel.Assertion

open Lean Elab Term in
/-- Embed the position of the surrounding assertion at compile time. -/
elab "hegelSource%" : term => do
  let ref ← getRef
  let map ← getFileMap
  let first := map.toPosition (ref.getPos?.getD 0)
  let last := map.toPosition (ref.getTailPos?.getD (ref.getPos?.getD 0))
  let file := Syntax.mkStrLit (← getFileName)
  let moduleName := Syntax.mkStrLit (← getEnv).mainModule.toString
  let line := Syntax.mkNumLit (toString first.line)
  let column := Syntax.mkNumLit (toString (first.column + 1))
  let endLine := Syntax.mkNumLit (toString last.line)
  let endColumn := Syntax.mkNumLit (toString (last.column + 1))
  elabTerm (← `({
    file := $file, moduleName := $moduleName, line := $line, column := $column
    endLine := $endLine, endColumn := $endColumn : Hegel.SourceLocation })) none

/-- Assert a Boolean with a stable origin derived from this source position. -/
syntax (name := hegelAssert) "assert! " term (" because " term)? : term
macro_rules
  | `(assert! $condition because $message) =>
    `(Hegel.Assertion.assertAt $condition $message hegelSource%)
  | `(assert! $condition) =>
    `(Hegel.Assertion.assertAt $condition "Assertion failed" hegelSource%)

-- Lean has its own `assert!` do-element. Give property assertions explicit do syntax too.
syntax (name := hegelAssertDo) (priority := high) "assert! " term (" because " term)? : doElem
macro_rules
  | `(doElem| assert! $condition because $message) =>
    `(doElem| Hegel.Assertion.assertAt $condition $message hegelSource%)
  | `(doElem| assert! $condition) =>
    `(doElem| Hegel.Assertion.assertAt $condition "Assertion failed" hegelSource%)

macro "assertEq! " actual:term:max expected:term:max : term =>
  `(Hegel.Assertion.equalAt $actual $expected hegelSource%)

macro "assertNe! " actual:term:max unexpected:term:max : term =>
  `(Hegel.Assertion.notEqualAt $actual $unexpected hegelSource%)

macro "assertProp! " proposition:term : term =>
  `(Hegel.Assertion.propAt $proposition hegelSource%)

macro "failure! " message:term : term =>
  `(Hegel.Assertion.failureAt $message hegelSource%)

macro "forAll! " gen:term : term =>
  `(Hegel.Assertion.forAllAt $gen hegelSource%)
