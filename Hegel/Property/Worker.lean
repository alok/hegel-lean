import Hegel.Property
import Std.Sync.Channel

namespace Hegel.Property.Worker

structure Result (α : Type) where
  outcome : Except Abort α
  notes : Array Note := #[]
  events : Array PoolEvent := #[]
  cleanupDiagnostics : Array CleanupDiagnostic := #[]

def native (action : EIO Internal.EngineError α) : EIO Abort α :=
  action.adapt fun error ↦
    if error.code == -1 then .overrun
    else if error.code == -2 then .discard
    else .error (toString error)

/-- Waiting on a child remains a cancellation boundary, so nested forks settle transitively. -/
private partial def waitReady (task : Task α) : BaseIO Unit := do
  unless ← IO.hasFinished task do
    if ← IO.checkCanceled then IO.cancel task
    IO.sleep 1
    waitReady task

def waitTask (task : Task α) : BaseIO α := do
  waitReady task
  IO.wait task

def checkDepth (context : Context) : EIO Abort Unit := do
  if context.cloneDepth >= context.settings.maxCloneDepth then
    throw (.error "Maximum property clone depth exceeded")

def childContext (parent : Context) (session : Internal.Session.type) : BaseIO Context := do
  let child ← Context.new session parent.settings
  return { child with
    cloneDepth := parent.cloneDepth + 1
    scope := parent.scope
    poolLabels := parent.poolLabels }

def run (context : Context) (action : Property α) : BaseIO (Result α) := do
  context.journal.set #[]
  context.events.set #[]
  context.clock.set 0
  context.cleanupDiagnostics.set #[]
  let outcome ← runInContext context action
  return {
    outcome, notes := ← context.journal.get, events := ← context.events.get
    cleanupDiagnostics := ← context.cleanupDiagnostics.get }

/-- Merge a completed worker at the join point, retaining its local event ordering. -/
def fold (index : Nat) (result : Result α) (label : String := "Branch") : Property Unit := do
  note (.branchHeader index) s!"{label} {index}"
  let parent ← getContext
  parent.cleanupDiagnostics.modify (· ++ result.cleanupDiagnostics)
  let offset ← parent.clock.get
  let maxClock := result.notes.foldl (fun n note ↦ max n (note.clock + 1)) 0
  let maxClock := result.events.foldl (fun n event ↦ max n (event.clock + 1)) maxClock
  parent.clock.set (offset + maxClock)
  parent.journal.modify (· ++ result.notes.map fun item ↦ {
    item with
    clock := offset + item.clock
    depth := parent.depth + item.depth + 1
    kind := match item.kind with | .failure diff => .branchFailure diff | kind => kind })
  parent.events.modify (· ++ result.events.map fun event ↦ {
    event with clock := offset + event.clock })

/-- Engine errors take precedence; ordinary branch failures use input order. -/
def chooseError (results : Array (Result α)) : Option Abort :=
  let errors := results.filterMap fun result ↦ match result.outcome with
    | .ok _ => none
    | .error error => some error
  errors.find? (fun error ↦ match error with | .error _ => true | _ => false)
    |>.orElse (fun _ ↦ errors.find? (fun error ↦ match error with | .overrun => true | _ => false))
    |>.orElse (fun _ ↦ errors.find? (fun error ↦ match error with | .discard => true | _ => false))
    |>.orElse (fun _ ↦ errors[0]?)

end Hegel.Property.Worker
