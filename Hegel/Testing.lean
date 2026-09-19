import Hegel.Arbitrary
import Hegel.Assertion
import Hegel.Runner
import Lean.Elab.Term

namespace Hegel

/-- Interpret a testable value as a property. Function arguments are generated and
recorded in order, including arguments whose types depend on previous values. -/
class Testable (α : Type) where
  toProperty : α → SourceLocation → Nat → Property Unit

instance : Testable Bool where
  toProperty value source _ := Assertion.assertAt value "Property is false" source

instance : Testable (Property Unit) where
  toProperty value _ _ := value

instance {α : Type} {β : α → Type} [Arbitrary α] [Repr α]
    [∀ a, Testable (β a)] : Testable ((a : α) → β a) where
  toProperty f source size := do
    let a ← Assertion.forAllAt (arbitrary size) source
    Testable.toProperty (f a) source size

/-- Turn a testable function into a property with a fixed size and source origin. -/
def property [Testable α] (value : α) (source : SourceLocation)
    (size : Nat := 30) : Property Unit := Testable.toProperty value source size

namespace Property

/-- Test a decidable proposition over generated values. Passing a finite campaign
does not prove the universally quantified proposition. -/
def forAllProp [Repr α] (gen : Gen α) (predicate : α → Prop)
    [DecidablePred predicate] (source : SourceLocation) : Property Unit := do
  let value ← Assertion.forAllAt gen source
  Assertion.propAt (predicate value) source

end Property

end Hegel

macro "property% " value:term : term =>
  `(Hegel.property $value hegelSource%)

macro "property% " "(" &"size" " := " size:term ")" value:term : term =>
  `(Hegel.property $value hegelSource% $size)

namespace Hegel.Testing
open Lean Meta Elab Term

private def testKind (name : Name) : MetaM Bool := do
  let info ← getConstInfo name
  if info matches .axiomInfo _ then
    throwError "@[hegel_test] requires an executable definition, not an axiom"
  if !info.levelParams.isEmpty then
    throwError "@[hegel_test] requires a closed, monomorphic Hegel.Test or Hegel.Property Unit"
  if ← isDefEq info.type (mkConst ``Hegel.Test) then return true
  if ← isDefEq info.type (mkApp (mkConst ``Hegel.Property) (mkConst ``Unit)) then return false
  throwError "@[hegel_test] requires Hegel.Test or Hegel.Property Unit; use property% to generate function arguments"

initialize testAttribute : TagAttribute ←
  registerTagAttribute `hegel_test "Register a compiled Hegel property for hegel_suite%."
    (fun name => MetaM.run' do let _ ← testKind name)

private def suite (ns : Name) : TermElabM Expr := do
  let env ← getEnv
  let names := env.constants.fold (init := #[]) fun names name _ =>
    if ns.isPrefixOf name && testAttribute.hasTag env name then names.push name else names
  let names := names.qsort (fun a b => a.toString < b.toString)
  if names.isEmpty then
    throwError "hegel_suite% found no registered tests; import your test modules before constructing the suite"
  let entries ← names.mapM fun name => do
    let decl := mkCIdent name
    if ← testKind name then `($decl)
    else `({ name := $(Syntax.mkStrLit name.toString), property := $decl : Hegel.Test })
  elabTerm (← `(#[$entries,*])) (some (mkApp (mkConst ``Array [0]) (mkConst ``Hegel.Test)))

elab "hegel_suite%" : term => suite .anonymous
elab "hegel_suite%" " in " ns:ident : term => suite ns.getId

end Hegel.Testing
