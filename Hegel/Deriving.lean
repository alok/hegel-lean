import Hegel.Arbitrary
import Lean.Elab.Deriving.Util
import Lean.Elab.Deriving.Basic

namespace Hegel.Deriving
open Lean Meta Elab Command Term

private def deriveArbitrary (name : Name) : CommandElabM Unit := do
  Lean.Elab.Deriving.withoutExposeFromCtors name do
  let ind ← getConstInfoInduct name
  if ind.numIndices != 0 then
    throwError "deriving Arbitrary does not support indexed inductives; define a size-aware instance explicitly"
  if ind.all.length != 1 then
    throwError "deriving Arbitrary does not support mutual inductives; define size-aware instances explicitly"
  let cmd ← liftTermElabM do
    let args ← Lean.Elab.Deriving.mkInductArgNames ind
    let binders ← Lean.Elab.Deriving.mkImplicitBinders args
    let instBinders := (← Lean.Elab.Deriving.mkInstImplicitBinders ``Arbitrary ind args).map
      (fun stx => (⟨stx⟩ : TSyntax ``Lean.Parser.Term.bracketedBinder))
    let target ← Lean.Elab.Deriving.mkInductiveApp ind args
    let size := mkIdent (← mkFreshUserName `size)
    let child := mkIdent (← mkFreshUserName `child)
    let mut choices : Array (TSyntax `term) := #[]
    let mut baseChoices : Array (TSyntax `term) := #[]
    for ctor in ind.ctors do
      let info ← getConstInfoCtor ctor
      let (branch, directRecursive) ← forallTelescopeReducing info.type fun xs _ => do
        let mut names : Array Name := args
        for _ in xs[ind.numParams:] do
          names := names.push (← mkFreshUserName `field)
        let mut lctx ← getLCtx
        for x in xs, n in names do
          lctx := lctx.setUserName x.fvarId! n
        withLCtx lctx (← getLocalInstances) do
          let ctorArgs := names.map mkIdent
          let fields ← xs[ind.numParams:].toArray.filterM fun x => return !(← isProof x)
          let divisor := Syntax.mkNumLit (toString (max fields.size 1))
          let fieldSize ← `($size / $divisor)
          let mut body ← `(pure (@$(mkCIdent ctor) $ctorArgs:ident*))
          for i in (List.range xs.size).reverse do
            if i < ind.numParams then continue
            let x := xs[i]!
            let field := mkIdent names[i]!
            let type ← PrettyPrinter.delab (← inferType x)
            if ← isType x then
              throwError "deriving Arbitrary cannot generate a type-valued field of {name}"
            if ← isProof x then
              body ← `(if $field:ident : $type then $body else Hegel.Gen.discard)
            else
              body ← `(Hegel.arbitrary (α := $type) $fieldSize >>= fun $field:ident => $body)
          let directRecursive ← xs[ind.numParams:].toArray.anyM fun x => do
            return (← whnf (← inferType x)).isAppOf ind.name
          return (body, directRecursive)
      choices := choices.push branch
      unless directRecursive do baseChoices := baseChoices.push branch
    let body ← if choices.isEmpty then `(Hegel.Gen.discard)
      else `(Hegel.Gen.oneOf #[$choices,*])
    let baseBody ← if baseChoices.isEmpty then `(Hegel.Gen.discard)
      else `(Hegel.Gen.oneOf #[$baseChoices,*])
    let body ← `(if $size == 0 then $baseBody else $body)
    let body ← `(Hegel.Gen.sizedFix (fun $child $size =>
      letI : Hegel.Arbitrary $target := ⟨$child⟩
      $body))
    `(instance $binders:implicitBinder* $instBinders:bracketedBinder* :
        Hegel.Arbitrary $target := ⟨$body⟩)
  elabCommand cmd

initialize registerDerivingHandler ``Arbitrary fun names => do
  for name in names do deriveArbitrary name
  return true

end Hegel.Deriving
