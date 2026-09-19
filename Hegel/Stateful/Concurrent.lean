import Hegel.Stateful
import Hegel.Property.Branch

/-! Concurrent state machines use persistent workers and join between concurrency groups. -/
namespace Hegel.Stateful.Concurrent

structure Rule (σ : Type) where
  name : String
  apply : σ → Property Unit
  group : Option String := none
  weight : Float := 1

def rule (name : String) (apply : σ → Property Unit) : Rule σ := ⟨name, apply, none, 1⟩

/-- Rules in a named group may overlap with that group; different groups never overlap. -/
def grouped (name group : String) (apply : σ → Property Unit) : Rule σ :=
  ⟨name, apply, some group, 1⟩

abbrev Invariant := Hegel.Stateful.Invariant

structure Machine (σ : Type) where
  initial : Property σ
  rules : Array (Rule σ)
  invariants : Array (Invariant σ) := #[]
  stepCount : Option Nat := none

structure Concurrency where
  minWorkers : Nat
  maxWorkers : Nat
  deriving Repr, BEq

def fixed (n : Nat) : Concurrency := ⟨n, n⟩
def between (min max : Nat) : Concurrency := ⟨min, max⟩
def upTo (max : Nat) : Concurrency := between 1 max

namespace Concurrency

def fixed (n : Nat) : Concurrency := Concurrent.fixed n
def between (min max : Nat) : Concurrency := Concurrent.between min max
def upTo (max : Nat) : Concurrency := Concurrent.upTo max

end Concurrency

def anonymousGroup : String := "<anonymous>"

/-- Dense group identifiers in first-appearance order; `none` remains distinct from any name. -/
def internGroups (labels : Array (Option String)) : Array (Option String) × Array Int64 := Id.run do
  let mut names := #[]
  let mut ids := #[]
  for label in labels do
    match names.findIdx? (· == label) with
    | some i => ids := ids.push i.toInt64
    | none =>
      ids := ids.push names.size.toInt64
      names := names.push label
  return (names, ids)

private def numberSteps (start : Nat) (counter : IO.Ref Nat) : Property Unit := do
  let context ← Property.getContext
  let mut notes ← context.journal.get
  let mut step ← counter.get
  for i in [start:notes.size] do
    if let some item := notes[i]? then
      if let .stepHeader _ name := item.kind then
        step := step + 1
        notes := notes.set! i { item with kind := .stepHeader step name }
  context.journal.set notes
  counter.set step

/-- Run rules on genuine persistent worker threads with one engine clone per worker.
Invariants run on the root only after all workers have joined. Mutable shared models must use
synchronization appropriate to the system being tested; scheduling is intentionally real. -/
partial def run (bounds : Concurrency) (machine : Machine σ) : Property Unit := do
  let (groupNames, groupIds) := internGroups (machine.rules.map (·.group))
  let (handle, workers) ← Stateful.Internal.acquire (machine.rules.map (·.name)) groupIds
    (machine.rules.map (·.weight)) (machine.invariants.map (·.name))
    (machine.invariants.map (·.alwaysCheck)) bounds.minWorkers bounds.maxWorkers machine.stepCount
  let model ← Property.withScope .caseSetup machine.initial
  Stateful.Internal.checkInvariants handle machine.invariants model true
  let step ← IO.mkRef (0 : Nat)
  Property.Branch.withWorkers workers fun team => do
    let mut round := 0
    repeat
      match ← Stateful.Internal.native (Hegel.Internal.machineGroup · handle) with
      | none =>
        Stateful.Internal.checkInvariants handle machine.invariants model true
        return
      | some group =>
        round := round + 1
        let label := ((groupNames[group]?).join).getD anonymousGroup
        Property.annotate s!"Round {round}, group {label}, workers {workers}"
        let actions := (Array.range workers).map fun worker => do
          Stateful.Internal.roundSpan do
            let rejected ← Stateful.Internal.workerRound handle worker fun index => do
              let some selected := machine.rules[index]?
                | throw (.error s!"Stateful.Concurrent.run: engine returned unknown rule {index}")
              Property.note (.stepHeader 0 selected.name) selected.name
              Property.note (.stepOrigin round (worker + 1) selected.group)
                s!"Round {round}, worker {worker + 1}"
              Property.nested (Property.withScope .inStep (selected.apply model))
            return ((), rejected)
        let start := (← (← Property.getContext).journal.get).size
        try team.runRound actions
        finally numberSteps start step
        step.modify (· + 1)
        Property.note (.roundBoundary (← step.get) round) s!"Round {round} invariant check"
        Stateful.Internal.checkInvariants handle machine.invariants model

end Hegel.Stateful.Concurrent
