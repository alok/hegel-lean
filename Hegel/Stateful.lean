import Hegel.Property
import Hegel.Internal.Stateful

/-! Stateful testing: engine-selected rules update a model and invariants check join points. -/
namespace Hegel.Stateful

structure Rule (σ : Type) where
  name : String
  apply : σ → Property σ
  weight : Float := 1

def rule (name : String) (apply : σ → Property σ) : Rule σ := ⟨name, apply, 1⟩

/-- By default every join point is checked. Set `alwaysCheck := false` for engine sampling;
initial and final checks remain unconditional. -/
structure Invariant (σ : Type) where
  name : String
  check : σ → Property Unit
  alwaysCheck : Bool := true

structure Machine (σ : Type) where
  initial : Property σ
  rules : Array (Rule σ)
  invariants : Array (Invariant σ) := #[]
  stepCount : Option Nat := none

/-- Record the current rule's response in the counterexample journal. -/
def respond (value : String) : Property Unit := Property.note .response value

def respondShow [Repr α] (value : α) : Property Unit := respond (reprStr value)

namespace Internal

def native (f : Hegel.Internal.Session.type → EIO Hegel.Internal.EngineError α) : Property α :=
  Property.draw (Gen.native f)

def acquire (names : Array String) (groups : Array Int64) (weights : Array Float)
    (invariants : Array String) (always : Array Bool) (lo hi : Nat) (stepCount : Option Nat) :
    Property (Hegel.Internal.MachineHandle.type × Nat) := do
  let steps := stepCount.getD (← Property.getContext).settings.statefulStepCount
  if names.isEmpty then throw (.error "Stateful.run: a machine needs at least one rule")
  if lo < 1 || hi < lo || hi > 9223372036854775807 then
    throw (.error "Stateful.run: worker bounds require 1 <= min <= max <= Int64.max")
  if steps < 1 || steps > 9223372036854775807 then
    throw (.error "Stateful.run: step count requires 1 <= steps <= Int64.max")
  let result ← native (Hegel.Internal.machineNew · names groups weights invariants always
    lo.toInt64 hi.toInt64 steps.toInt64)
  Property.registerFinalizer
    ((Hegel.Internal.machineClose result.1).toIO (IO.userError ∘ toString))
  return result

def checkInvariants (machine : Hegel.Internal.MachineHandle.type)
    (invariants : Array (Invariant σ)) (state : σ) (guaranteed : Bool := false) :
    Property Unit := do
  for h : i in [:invariants.size] do
    let invariant := invariants[i]
    if guaranteed || (← native (Hegel.Internal.machineInvariant · machine i.toUInt64)) then
      Property.annotate s!"Invariant: {invariant.name}"
      Property.nested (Property.withScope .inStep (invariant.check state))

/-- Keep a round's scheduler draws and rule body in one shrinkable span. -/
def roundSpan (action : Property (α × Bool)) : Property α := fun context => do
  let session := context.session
  Gen.native (Hegel.Internal.startSpan · "lean.stateful.round") session
  let outcome ← (action context).toBaseIO
  match outcome with
  | .ok (value, rejected) =>
    Gen.native (Hegel.Internal.stopSpan · rejected) session
    return value
  | .error e =>
    let _ ← (Hegel.Internal.stopSpan session false).toBaseIO
    throw e

/-- Apply one engine-assigned worker round. Only a rule body's discard is recoverable;
errors and overrun escape, as do discards from the scheduler itself. -/
partial def workerRound (machine : Hegel.Internal.MachineHandle.type) (worker : Nat)
    (dispatch : Nat → Property Unit) : Property Bool := do
  let mut rejected := false
  repeat
    match ← native (Hegel.Internal.machineRule · machine worker.toUInt64) with
    | none => return rejected
    | some index =>
      try dispatch index
      catch
      | .discard =>
        native (Hegel.Internal.machineRejected · machine worker.toUInt64)
        Property.annotate "Rule stopped early due to violated assumption"
        rejected := true
      | e => throw e
  return rejected

end Internal

/-- Run setup and all invariants, then thread the model through engine-selected rules.
A rejected rule preserves the prior model and does not discard the entire case. -/
partial def run (machine : Machine σ) : Property Unit := do
  let (handle, _) ← Internal.acquire (machine.rules.map (·.name))
    (machine.rules.map (fun _ => (0 : Int64))) (machine.rules.map (·.weight))
    (machine.invariants.map (·.name)) (machine.invariants.map (·.alwaysCheck)) 1 1 machine.stepCount
  let initial ← Property.withScope .caseSetup machine.initial
  Internal.checkInvariants handle machine.invariants initial true
  let state ← IO.mkRef initial
  let step ← IO.mkRef (0 : Nat)
  repeat
    let more ← Internal.roundSpan do
      match ← Internal.native (Hegel.Internal.machineGroup · handle) with
      | none => return (false, false)
      | some _ =>
        let rejected ← Internal.workerRound handle 0 fun index => do
          let some selected := machine.rules[index]?
            | throw (.error s!"Stateful.run: engine returned unknown rule {index}")
          step.modify (· + 1)
          Property.note (.stepHeader (← step.get) selected.name) selected.name
          let updated ← Property.nested (Property.withScope .inStep (selected.apply (← state.get)))
          state.set updated
        return (true, rejected)
    Internal.checkInvariants handle machine.invariants (← state.get) (!more)
    unless more do return

end Hegel.Stateful
