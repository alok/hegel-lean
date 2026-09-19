import Hegel.Runner
import Hegel.Property.Branch
import Hegel.Property.Fork
import Hegel.Property.Worker
import Std.Sync.Mutex
import Std.Sync.Channel

namespace Tests.Concurrency
open Hegel Hegel.Property

private def settings : Settings := { seed := some 42, maxExamples := 20, database := none }

private def log (message : String) : IO Unit := do
  IO.println message
  (← IO.getStdout).flush

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def passes (name : String) (property : Property Unit) : IO Unit := do
  let report ← check name property settings
  require report.isSuccess report.render
  log s!"ok: {name}"

private def rejects (name : String) (property : Property Unit) (config : Settings := settings) :
    IO Unit := do
  let report ← check name property config
  require (report.outcome == .error) s!"Expected error, got {report.render}"
  log s!"ok: {name}"

private def failureReplay (name : String) (property : Property Unit) : IO Failure := do
  let report ← check name property settings
  require (report.outcome == .failed && !report.failures.isEmpty) report.render
  let failure := report.failures[0]!
  require (!failure.blob.isEmpty) "Deterministic child failure must retain its replay blob"
  for _ in [:2] do
    let again ← replay failure.blob property settings
    require (again.status == .failed && again.origin == failure.origin)
      "Child failure changed origin on replay"
    require (again.annotations == failure.annotations)
      "Child failure changed observations on replay"
  log s!"ok: {name}"
  return failure

private def childFailure : Property Unit := do
  let value ← forAll (Gen.nat 0 100) "child value"
  assertThat (value < 5) "child/minimum"

private partial def cancellable (started : Std.Channel.Sync Unit) (finished : IO.Ref Bool) :
    Property Unit := do
  registerFinalizer (finished.set true)
  started.send ()
  repeat
    io (IO.sleep 1)

private def nestedCancellation (mode : Nat) : Property Unit := do
  let started ← Std.Channel.Sync.new
  let finished ← IO.mkRef false
  let outer ← Hegel.Property.Fork.spawn do
    let action := cancellable started finished
    match mode with
    | 0 =>
      let inner ← Hegel.Property.Fork.spawn action
      Hegel.Property.Fork.join inner
    | 1 => Hegel.Property.Branch.replicateConcurrently_ 1 action
    | _ => Hegel.Property.Branch.withWorkers 1 fun team => team.runRound #[action]
  started.recv
  Hegel.Property.Fork.cancel outer
  assertThat (← finished.get) "fork/nested cancellation cleanup"

/-- Native streams, real dedicated workers, and deterministic join order. -/
def run : IO Unit := do
  let forkCounterexample ← failureReplay "joined fork failures shrink and replay" do
    let fork ← Hegel.Property.Fork.spawn childFailure
    Hegel.Property.Fork.join fork
  require (forkCounterexample.annotations.contains "child value = 5")
    "Fork failure did not shrink to five"
  let branchCounterexample ← failureReplay "branch failures shrink and replay" do
    let _ ← Hegel.Property.Branch.concurrently (pure (37 : Nat)) childFailure
    pure ()
  require (branchCounterexample.annotations.contains "child value = 5")
    "Branch failure did not shrink to five"
  passes "repeated joins fold observations once" do
    let fork ← Hegel.Property.Fork.spawn do annotate "one child observation"; return (17 : Nat)
    assertEq (← Hegel.Property.Fork.join fork) 17 "fork/result"
    assertEq (← Hegel.Property.Fork.join fork) 17 "fork/repeated result"
    let notes ← (← getContext).journal.get
    assertEq (notes.filter (·.text == "one child observation")).size 1 "fork/fold once"
  passes "poll reports pending and completed without joining" do
    let ready ← Std.Channel.Sync.new
    let unblock ← Std.Channel.Sync.new
    let fork ← Hegel.Property.Fork.spawn do
      ready.send ()
      unblock.recv
      return (11 : Nat)
    ready.recv
    assertThat (← Hegel.Property.Fork.poll fork).isNone "fork/pending"
    unblock.send ()
    let mut complete := false
    for _ in [:1000] do
      if (← Hegel.Property.Fork.poll fork).isSome then complete := true; break
      io (IO.sleep 1)
    assertThat complete "fork/completed"
    assertEq (← Hegel.Property.Fork.join fork) 11 "fork/polled result"
  rejects "poll does not discharge join obligation" do
    let fork ← Hegel.Property.Fork.spawn (pure (0 : Nat))
    let _ ← Hegel.Property.Fork.poll fork
    pure ()
  rejects "ignored failing fork is malformed" do
    let _ ← Hegel.Property.Fork.spawn (failure "ignored fork failure" : Property Unit)
    pure ()
  passes "cancel settles and releases a live worker" do
    let started ← Std.Channel.Sync.new
    let finished ← IO.mkRef false
    let fork ← Hegel.Property.Fork.spawn (cancellable started finished)
    started.recv
    Hegel.Property.Fork.cancel fork
    Hegel.Property.Fork.cancel fork
    assertThat (← finished.get) "fork/cancellation cleanup"
    let mut rejected := false
    try Hegel.Property.Fork.join fork
    catch
    | .error _ => rejected := true
    | other => throw other
    assertThat rejected "fork/join after cancel"
  for implicitCancel in #[false, true] do
    let name := if implicitCancel then "implicit fork cleanup errors remain visible"
      else "explicit fork cleanup errors remain visible"
    let report ← check name (do
      let started ← Std.Channel.Sync.new
      let finished ← IO.mkRef false
      let fork ← Hegel.Property.Fork.spawn do
        registerFinalizer (throw (IO.userError "fork release failed"))
        cancellable started finished
      started.recv
      unless implicitCancel do
        try Hegel.Property.Fork.cancel fork
        catch
        | .error _ => pure ()
        | other => throw other) settings
    require (report.outcome == .error) report.render
    require (report.cleanupDiagnostics.size == 1 &&
      report.cleanupDiagnostics[0]!.message.contains "fork release failed")
      "Cancelled fork lost or duplicated its cleanup diagnostic"
    log s!"ok: {name}"
  passes "scoped fork cancels and cleans up on block exit" do
    let started ← Std.Channel.Sync.new
    let finished ← IO.mkRef false
    Hegel.Property.Fork.scoped (cancellable started finished) fun _ => do started.recv
    assertThat (← finished.get) "fork/scoped cleanup"
  passes "scoped fork cleanup also runs after caught failure" do
    let started ← Std.Channel.Sync.new
    let finished ← IO.mkRef false
    try
      Hegel.Property.Fork.scoped (cancellable started finished) fun _ => do
        started.recv
        failure "scoped/body failure"
    catch
    | .failure "scoped/body failure" _ => pure ()
    | other => throw other
    assertThat (← finished.get) "fork/scoped exceptional cleanup"
  passes "cancellation propagates through a nested fork join" (nestedCancellation 0)
  passes "cancellation propagates through a nested branch join" (nestedCancellation 1)
  passes "cancellation propagates through a persistent worker round" (nestedCancellation 2)
  passes "bounded cancellation releases unstarted clones without running their bodies" do
    let started ← Std.Channel.Sync.new
    let finished ← IO.mkRef false
    let executions ← Std.Mutex.new (0 : Nat)
    let outer ← Hegel.Property.Fork.spawn do
      Hegel.Property.Branch.replicateConcurrentlyBounded 1 5 do
        io (executions.atomically (modify (· + 1)))
        cancellable started finished
    started.recv
    Hegel.Property.Fork.cancel outer
    assertEq (← io (executions.atomically get)) 1 "branch/cancel unstarted bodies"
    assertThat (← finished.get) "branch/cancel started cleanup"
  let saved ← IO.mkRef (none : Option (Hegel.Property.Fork.Fork Nat))
  passes "fork handle scope setup" do
    let fork ← Hegel.Property.Fork.spawn (pure (13 : Nat))
    saved.set (some fork)
    let _ ← Hegel.Property.Fork.join fork
    pure ()
  let some stale ← saved.get | throw (IO.userError "No retained fork handle")
  rejects "fork cannot escape its property lifetime" do let _ ← Hegel.Property.Fork.join stale
  rejects "fork clone depth cap" (do
    let _ ← Hegel.Property.Fork.spawn (pure (0 : Nat))
    pure ()) { settings with maxCloneDepth := 0 }
  rejects "nested branch clone depth cap" (do
    let _ ← Hegel.Property.Branch.replicateConcurrently 1 do
      let _ ← Hegel.Property.Branch.replicateConcurrently 1 (pure (0 : Nat))
      pure ()
    pure ()) { settings with maxCloneDepth := 1 }
  passes "concurrent map preserves input order" do
    let results ← Hegel.Property.Branch.mapConcurrently (fun n => do
      io (IO.sleep (6 - n).toUInt32)
      return n * n) #[0, 1, 2, 3, 4, 5]
    assertEq results #[0, 1, 4, 9, 16, 25] "branch/input order"
  passes "bounded replication respects the concurrency cap" do
    let state ← Std.Mutex.new ((0, 0, 0) : Nat × Nat × Nat)
    let values ← Hegel.Property.Branch.replicateConcurrentlyBounded 2 7 do
      let id ← io <| state.atomically do
        let (active, peak, total) ← get
        set (active + 1, max peak (active + 1), total + 1)
        return total
      io (IO.sleep 1)
      io <| state.atomically do
        let (active, peak, total) ← get
        set (active - 1, peak, total)
      return id
    let (active, peak, total) ← io (state.atomically get)
    assertEq active 0 "branch/all joined"
    assertThat (peak ≤ 2) "branch/cap"
    assertEq total 7 "branch/count"
    assertEq values.size 7 "branch/results"
  rejects "zero concurrency cap" do
    let _ ← Hegel.Property.Branch.replicateConcurrentlyBounded 0 1 (pure (0 : Nat))
    pure ()
  passes "empty fan-out produces no workers" do
    let values ← Hegel.Property.Branch.mapConcurrently (fun (n : Nat) => pure n) #[]
    assertEq values (#[] : Array Nat) "branch/empty"
  passes "all branch cleanup runs before failures return" do
    let releases ← Std.Mutex.new (0 : Nat)
    try
      Hegel.Property.Branch.replicateConcurrently_ (α := Unit) 3 do
        registerFinalizer (releases.atomically (modify (· + 1)))
        failure "branch/expected failure"
    catch
    | .failure "branch/expected failure" _ => pure ()
    | other => throw other
    assertEq (← io (releases.atomically get)) 3 "branch/all cleanup"
  passes "worker acquisition preserves native control signals" do
    try
      Hegel.Property.Worker.native (throw ⟨-1, "choice budget exhausted"⟩ :
        EIO Hegel.Internal.EngineError Unit)
      failure "worker/missing native overrun"
    catch
    | .overrun => pure ()
    | other => throw other
    try
      Hegel.Property.Worker.native (throw ⟨-2, "assumption rejected"⟩ :
        EIO Hegel.Internal.EngineError Unit)
      failure "worker/missing native discard"
    catch
    | .discard => pure ()
    | other => throw other
  passes "branch control outcomes outrank ordinary failures" do
    let actions : Array (Property Unit) := #[
      failure "ordinary failure", throw .discard, throw .overrun,
      throw (.error "engine control error")]
    let observed ← IO.mkRef ""
    try let _ ← Hegel.Property.Branch.mapConcurrently id actions
    catch
    | .error message => observed.set message
    | other => throw other
    assertEq (← observed.get) "engine control error" "branch/error precedence"
    try
      let _ ← Hegel.Property.Branch.concurrently
        (failure "ordinary failure" : Property Unit) (throw .overrun : Property Unit)
      failure "branch/missing overrun"
    catch
    | .overrun => pure ()
    | other => throw other
    try
      let _ ← Hegel.Property.Branch.concurrently
        (failure "ordinary failure" : Property Unit) (throw .discard : Property Unit)
      failure "branch/missing discard"
    catch
    | .discard => pure ()
    | other => throw other
  passes "persistent workers reject invalid action counts and close scopes" do
    Hegel.Property.Branch.withWorkers 2 fun team => do
      let mut rejected := false
      try team.runRound #[pure ()]
      catch
      | .error _ => rejected := true
      | other => throw other
      assertThat rejected "branch/team arity"
      team.runRound #[pure (), pure ()]
      team.runRound #[pure (), pure ()]

end Tests.Concurrency
