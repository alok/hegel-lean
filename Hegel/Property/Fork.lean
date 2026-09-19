import Hegel.Property.Worker

namespace Hegel.Property.Fork

structure Fork (α : Type) where
  private task : Task (Worker.Result α)
  private settled : IO.Ref Bool
  private cancelled : IO.Ref Bool
  private alive : IO.Ref Bool
  private index : Nat

/-- Start a dedicated worker after allocating its stream in deterministic parent order. -/
def spawn (body : Property α) : Property (Fork α) := do
  let parent ← getContext
  Worker.checkDepth parent
  let session ← Worker.native (Internal.clone parent.session)
  let child ← Worker.childContext parent session
  let task ← BaseIO.asTask (do
    let result ← Worker.run child body
    match ← (Worker.native (Internal.close session)).toBaseIO with
    | .ok () => return result
    | .error error => return { result with
        outcome := .error error
        cleanupDiagnostics := result.cleanupDiagnostics.push {
          message := "Closing fork stream: " ++ reprStr error } }) .dedicated
  let settled ← IO.mkRef false
  let cancelled ← IO.mkRef false
  let alive ← IO.mkRef true
  let index := (← parent.forks.get).size + 1
  parent.forks.modify (·.push { settled, cancel := do
    cancelled.set true
    IO.cancel task
    let result ← IO.wait task
    parent.cleanupDiagnostics.modify (· ++ result.cleanupDiagnostics) })
  registerFinalizer (alive.set false)
  return { task, settled, cancelled, alive, index }

private def validate (fork : Fork α) : Property Unit := do
  unless ← fork.alive.get do throw (.error "Fork used after its property scope ended")

/-- Wait for the worker, importing its observations only on the first join. -/
def join (fork : Fork α) : Property α := do
  validate fork
  if ← fork.cancelled.get then throw (.error "Cannot join a cancelled fork")
  let result ← Worker.waitTask fork.task
  unless ← fork.settled.get do
    Worker.fold fork.index result "Fork"
    fork.settled.set true
  match result.outcome with
  | .ok value => return value
  | .error error => throw error

/-- Cancellation is cooperative at generator draws and `Property.io` boundaries. -/
def cancel (fork : Fork α) : Property Unit := do
  validate fork
  unless ← fork.settled.get do
    fork.cancelled.set true
    IO.cancel fork.task
    let result ← IO.wait fork.task
    fork.settled.set true
    (← getContext).cleanupDiagnostics.modify (· ++ result.cleanupDiagnostics)
    unless result.cleanupDiagnostics.isEmpty do
      throw (.error "Resource cleanup failed while cancelling a fork")

/-- Inspect completion without discharging the obligation to join or cancel. -/
def poll (fork : Fork α) : Property (Option (Except Abort α)) := do
  validate fork
  if ← IO.hasFinished fork.task then
    return some (← IO.wait fork.task).outcome
  return none

/-- Bound a worker's lifetime to a block; an unjoined worker is cancelled on every exit. -/
def «scoped» (body : Property α) (use : Fork α → Property β) : Property β := fun context ↦ do
  let fork ← spawn body context
  let result ← (use fork context).toBaseIO
  let cleanup ← (cancel fork context).toBaseIO
  match result, cleanup with
  | .error error, _ => throw error
  | .ok _, .error error => throw error
  | .ok value, .ok () => return value

end Hegel.Property.Fork
