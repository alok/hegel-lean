import Hegel.Runner
import Hegel.Stateful.Concurrent
import Hegel.Pool
import Hegel.Collection
import Std.Sync.Mutex

namespace Tests.Stateful
open Hegel Hegel.Property

private def settings : Settings :=
  { seed := some 42, maxExamples := 40, database := none, statefulStepCount := 8 }

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def passes (name : String) (property : Property Unit) : IO Unit := do
  let report ← check name property settings
  require report.isSuccess report.render
  IO.println s!"ok: {name}"

private def rejects (name : String) (property : Property Unit) : IO Unit := do
  let report ← check name property settings
  require (report.outcome == .error) s!"Expected invalid configuration: {report.render}"
  IO.println s!"ok: {name}"

private def counter : Hegel.Stateful.Machine Nat := {
  initial := pure 0
  rules := #[Hegel.Stateful.rule "increment" (fun n => pure (n + 1))]
  invariants := #[{ name := "counter bound", check := fun n => do
    annotate s!"counter={n}"
    assertThat (n < 3) "counter/bound" }]
}

private structure ConcurrentModel where
  state : Std.Mutex (Nat × Nat × Option String × Bool)

private def concurrentRule (group : String) (model : ConcurrentModel) : Property Unit := do
  let mixed ← io <| model.state.atomically do
    let (entered, active, oldGroup, mixed) ← get
    let invalid := mixed || (active > 0 && oldGroup != some group)
    set (entered + 1, active + 1, some group, invalid)
    return invalid
  assertThat (!mixed) "concurrency/group isolation"
  io (IO.sleep 1)
  io <| model.state.atomically do
    let (entered, active, label, mixed) ← get
    set (entered, active - 1, label, mixed)

private def joinedInvariant : Hegel.Stateful.Invariant ConcurrentModel := {
  name := "all workers joined"
  check := fun model => do
    let (_, active, _, mixed) ← io (model.state.atomically get)
    assertEq active 0 "concurrency/join"
    assertThat (!mixed) "concurrency/group isolation"
}

private def overlapRule (observed : Std.Mutex Bool) (active : Std.Mutex Nat) : Property Unit := do
  let concurrent ← io <| active.atomically do
    modify (· + 1)
    return decide ((← get) ≥ 2)
  if concurrent then io (observed.atomically (set true))
  io (IO.sleep 2)
  io (active.atomically (modify (· - 1)))

/-- Native integration tests; no simulated scheduler or in-memory substitute for engine draws. -/
def run : IO Unit := do
  let report ← check "stateful counter minimum" (Hegel.Stateful.run counter) settings
  require (report.outcome == .failed && report.failures.size == 1) report.render
  let counterexample := report.failures[0]!
  require (counterexample.annotations.contains "counter=3")
    "State machine did not shrink to three increments"
  for _ in [:2] do
    let replayed ← replay counterexample.blob (Hegel.Stateful.run counter) settings
    require (replayed.origin == "counter/bound") "State machine replay changed failure origin"
    require (replayed.annotations == counterexample.annotations)
      "State machine replay changed its trace"
  IO.println "ok: stateful counter shrinks to three increments and replays"
  let initialized ← IO.mkRef false
  let initialFailure : Hegel.Stateful.Machine Nat := {
    initial := pure 0
    rules := #[Hegel.Stateful.rule "must not run" fun n => do initialized.set true; return n]
    invariants := #[{ name := "initial", check := fun _ => failure "initial/invariant" }]
  }
  let report ← check "stateful initial invariant" (Hegel.Stateful.run initialFailure) settings
  require (report.outcome == .failed && !(← initialized.get)) "Initial invariant ran after a rule"
  IO.println "ok: stateful initial invariant precedes rules"
  passes "stateful rejected preconditions skip only the rule" do
    let first ← IO.mkRef true
    Hegel.Stateful.run {
      initial := pure 0
      rules := #[Hegel.Stateful.rule "increment after rejected attempt" fun n => do
        let reject ← first.get
        first.set false
        assume (!reject)
        return n + 1]
      invariants := #[{ name := "bound", check := fun n => assertThat (n ≤ 8) "step budget" }]
    }
  passes "sampled invariants retain initial and final checks" do
    let observations ← IO.mkRef (#[] : Array Nat)
    Hegel.Stateful.run {
      initial := pure 0
      rules := #[Hegel.Stateful.rule "increment" (fun n => pure (n + 1))]
      invariants := #[{
        name := "sampled"
        alwaysCheck := false
        check := fun n => observations.modify (·.push n) }]
      stepCount := some 1
    }
    assertEq (← observations.get) #[0, 1, 1] "invariant/initial join final"
  passes "pool identity, reuse, consume, and transfer" do
    let source ← Pool.named "source"
    let destination ← Pool.named "destination"
    Pool.add source ("zero" : String)
    Pool.add source "one"
    assertEq (← io source.size) 2 "pool/size"
    let reused ← draw source.reuse
    assertThat (reused == "zero" || reused == "one") "pool/member"
    assertEq (← io source.size) 2 "pool/reuse size"
    let moved ← draw (source.transfer destination)
    assertEq (← io source.size) 1 "pool/transfer source"
    assertEq (← io destination.size) 1 "pool/transfer destination"
    assertEq (← draw destination.consume) moved "pool/transfer value"
    assertThat (← io destination.isEmpty) "pool/empty after consume"
    let mut rejected := false
    try let _ ← draw destination.reuse
    catch
    | .discard => rejected := true
    | e => throw e
    assertThat rejected "pool/empty discards"
    let remaining ← draw source.consume
    assertThat (remaining != moved) "pool/consume distinct"
    assertThat (← io source.isEmpty) "pool/drained"
  let poolTrace : Property Unit := do
    let source ← Pool.named "handles"
    let destination ← Pool.named "closed"
    Pool.add source (37 : Nat)
    let _ ← draw source.reuse
    let _ ← draw (source.transfer destination)
    let _ ← draw destination.consume
    failure "pool/trace"
  let traced ← check "pool trace and lineage" poolTrace settings
  require (traced.outcome == .failed && traced.failures.size == 1) traced.render
  let events := traced.failures[0]!.trace.events
  require (events.size == 5) s!"Expected all five pool events, got {reprStr events}"
  require (events[0]!.operation == .add && events[1]!.operation == .reuse &&
    events[2]!.operation == .consume && events[3]!.operation == .transfer events[0]!.ref &&
    events[4]!.operation == .consume) "Pool lineage or event order was lost"
  require ((events.toList.take 3).all (·.label == some "handles") &&
    (events.toList.drop 3).all (·.label == some "closed")) "Named pool labels were lost"
  let again ← replay traced.failures[0]!.blob poolTrace settings
  require (again.events == events) "Pool identities, labels, or event ordering changed on replay"
  IO.println "ok: named pool lineage and native identities survive replay"
  let retained ← IO.mkRef (none : Option (Pool Nat))
  let cleanupFailure : Property Unit := do
    let pool ← Pool.new
    Pool.add pool (11 : Nat)
    retained.set (some pool)
    failure "pool/cleanup on failure"
  let cleanupReport ← check "pool cleanup after failure" cleanupFailure settings
  require (cleanupReport.outcome == .failed) cleanupReport.render
  let some closed ← retained.get | throw (IO.userError "Pool cleanup test did not allocate")
  let result ← closed.size.toBaseIO
  require (match result with | .error _ => true | .ok _ => false)
    "A retained pool was not released after a failing case"
  rejects "retained pool cannot cross test-case families" do
    let _ ← draw closed.reuse
    pure ()
  IO.println "ok: pool cleanup after failure invalidates retained handles"
  passes "pool transfer to itself preserves cardinality" do
    let pool ← Pool.new
    Pool.add pool (37 : Nat)
    assertEq (← draw (pool.transfer pool)) 37 "pool/self transfer value"
    assertEq (← io pool.size) 1 "pool/self transfer size"
  passes "scoped collection finish is idempotent" do
    draw <| Collection.with 1 1 fun collection => do
      if !(← collection.more) then throw (.failure "collection/start" "Expected one element")
      if ← collection.more then throw (.failure "collection/end" "Expected the collection to end")
      for _ in [:10] do
        collection.reject
        if ← collection.more then
          throw (.failure "collection/reopened" "Completed collection reopened")
  rejects "pool allocation inside rule" do
    Hegel.Stateful.run {
      initial := pure ()
      rules := #[Hegel.Stateful.rule "invalid allocation" fun _ => do
        let _ : Pool Nat ← Pool.new
        pure ()]
    }
  rejects "empty state machine" (Hegel.Stateful.run { initial := pure (), rules := #[] })
  rejects "zero step budget" (Hegel.Stateful.run { counter with stepCount := some 0 })
  rejects "nonpositive rule weight" (Hegel.Stateful.run {
    initial := pure (), rules := #[{ name := "bad", apply := pure, weight := 0 }] })
  rejects "embedded NUL rule name" (Hegel.Stateful.run {
    initial := pure (), rules := #[Hegel.Stateful.rule "bad\x00name" pure] })
  rejects "zero workers" (Hegel.Stateful.Concurrent.run (.fixed 0) {
    initial := pure (), rules := #[Hegel.Stateful.Concurrent.rule "noop" (fun _ => pure ())] })
  let (groups, ids) := Hegel.Stateful.Concurrent.internGroups
    #[none, some "writers", none, some "readers", some "writers", some "<anonymous>"]
  require (groups == #[none, some "writers", some "readers", some "<anonymous>"] &&
    ids == #[0, 1, 0, 2, 1, 3]) "Concurrency group identities are unstable"
  IO.println "ok: concurrency group interning"
  let observedOverlap ← Std.Mutex.new false
  passes "concurrent rules use genuinely overlapping workers" do
    Hegel.Stateful.Concurrent.run (.fixed 2) {
      initial := io (Std.Mutex.new 0)
      rules := #[Hegel.Stateful.Concurrent.rule "overlap" (overlapRule observedOverlap)]
      stepCount := some 2
    }
  require (← observedOverlap.atomically get) "No actual worker overlap was observed in the campaign"
  passes "concurrency groups and joined invariants" do
    Hegel.Stateful.Concurrent.run (.between 2 3) {
      initial := return { state := ← Std.Mutex.new (0, 0, none, false) }
      rules := #[Hegel.Stateful.Concurrent.grouped "writer" "writers" (concurrentRule "writers"),
        Hegel.Stateful.Concurrent.grouped "reader" "readers" (concurrentRule "readers")]
      invariants := #[joinedInvariant]
      stepCount := some 3
    }
  passes "concurrent workers share native pools" do
    Hegel.Stateful.Concurrent.run (.fixed 3) {
      initial := do
        let pool ← Pool.named "shared"
        for n in [:5] do Pool.add pool n
        return pool
      rules := #[Hegel.Stateful.Concurrent.rule "reuse" fun pool => do
        let n ← draw pool.reuse
        assertThat (n < 5) "pool/concurrent membership"]
      invariants := #[{ name := "pool preserved", check := fun pool => do
        assertEq (← io pool.size) 5 "pool/concurrent size" }]
      stepCount := some 2
    }
  let concurrentFailure := Hegel.Stateful.Concurrent.run (.fixed 2) {
    initial := pure ()
    rules := #[Hegel.Stateful.Concurrent.rule "failure" fun _ => do
      annotate "observed on worker"
      failure "concurrency/worker failure"]
    stepCount := some 1
  }
  let report ← check "concurrent failures preserve observations" concurrentFailure settings
  require (report.outcome == .nondeterministic && !report.failures.isEmpty) report.render
  require (report.failures[0]!.blob.isEmpty) "Nondeterministic failure must not claim a replay blob"
  require (report.failures[0]!.annotations.contains "observed on worker")
    "Concurrent failure lost the discovering execution journal"
  let indices := report.failures[0]!.notes.filterMap fun note => match note.kind with
    | .stepHeader index _ => some index
    | _ => none
  require (indices == (Array.range indices.size).map (· + 1))
    "Concurrent steps were not numbered in joined worker order"
  IO.println "ok: concurrent failure preserves observations without claiming deterministic replay"

end Tests.Stateful
