import Hegel.Property.Worker

namespace Hegel.Property.Branch

private structure Worker where
  requests : Std.Channel.Sync (Option (Property Unit))
  responses : Std.Channel.Sync (Option (Property.Worker.Result Unit))
  task : Task (Except Abort Unit)

private partial def workerLoop (context : Context)
    (requests : Std.Channel.Sync (Option (Property Unit)))
    (responses : Std.Channel.Sync (Option (Property.Worker.Result Unit))) : BaseIO Unit := do
  match ← requests.recv with
  | none => return
  | some action =>
    responses.send (some (← Property.Worker.run context action))
    workerLoop context requests responses

structure WorkerTeam where
  private workers : Array Worker
  private closed : IO.Ref Bool

private partial def waitResponse (team : WorkerTeam) (worker : Worker) :
    BaseIO (Option (Property.Worker.Result Unit)) := do
  match ← worker.responses.tryRecv with
  | some response => return response
  | none =>
    if ← IO.checkCanceled then
      for member in team.workers do IO.cancel member.task
    IO.sleep 1
    waitResponse team worker

/-- Dispatch one round to persistent threads, then join every worker before returning. -/
def WorkerTeam.runRound (team : WorkerTeam) (actions : Array (Property Unit)) : Property Unit := do
  if ← team.closed.get then throw (.error "Worker team has already closed")
  unless actions.size == team.workers.size do
    throw (.error "Worker round must supply exactly one action per worker")
  for (worker, action) in team.workers.zip actions do worker.requests.send (some action)
  let mut results := #[]
  for worker in team.workers do
    let some result ← waitResponse team worker | throw (.error "Worker ended without a result")
    results := results.push result
  for (result, index) in results.zipIdx do
    Property.Worker.fold (index + 1) result
  if let some error := Property.Worker.chooseError results then throw error

private def stop (team : WorkerTeam) : BaseIO (Option Abort) := do
  if ← team.closed.get then return none
  team.closed.set true
  for worker in team.workers do worker.requests.send none
  let mut error := none
  for worker in team.workers do
    if let .error e ← IO.wait worker.task then error := error.orElse fun _ ↦ some e
  return error

private def acquire (parent : Context) (count : Nat) : EIO Abort (Array Internal.Session.type) := do
  let sessions ← IO.mkRef #[]
  try
    for _ in [:count] do
      if ← IO.checkCanceled then throw (.error "Property cancelled")
      let session ← Property.Worker.native (Internal.clone parent.session)
      sessions.modify (·.push session)
    sessions.get
  catch error =>
    for session in ← sessions.get do let _ ← (Internal.close session).toBaseIO
    throw error

/-- A dedicated OS thread owns each cloned stream for the entire block, including idle rounds. -/
def withWorkers (count : Nat) (body : WorkerTeam → Property α) : Property α := fun parent ↦ do
  Property.Worker.checkDepth parent
  let sessions ← acquire parent count
  let mut workers := #[]
  for session in sessions do
    let context ← Property.Worker.childContext parent session
    let requests ← Std.Channel.Sync.new
    let responses ← Std.Channel.Sync.new
    let task ← BaseIO.asTask (do
      workerLoop context requests responses
      (Property.Worker.native (Internal.close session)).toBaseIO) .dedicated
    workers := workers.push { requests, responses, task }
  let team := { workers, closed := ← IO.mkRef false : WorkerTeam }
  let result ← (body team parent).toBaseIO
  let cleanup ← stop team
  match result, cleanup with
  | .error error, _ => throw error
  | .ok _, some error => throw error
  | .ok value, none => return value

private def runBranches (cap : Nat)
    (actions : Array (Property α)) : Property (Array α) := fun parent ↦ do
  if cap == 0 then throw (.error "Concurrency cap must be at least one")
  if actions.isEmpty then return #[]
  Property.Worker.checkDepth parent
  let sessions ← acquire parent actions.size
  let mut results := #[]
  let jobs := sessions.zip actions
  let mut start := 0
  while start < actions.size do
    if ← IO.checkCanceled then
      for session in sessions.toList.drop start do
        let _ ← (Internal.close session).toBaseIO
      throw (.error "Property cancelled")
    let mut tasks := #[]
    for (session, action) in jobs.toList.drop start |>.take cap do
      let context ← Property.Worker.childContext parent session
      let task ← BaseIO.asTask (do
        let result ← Property.Worker.run context action
        match ← (Property.Worker.native (Internal.close session)).toBaseIO with
        | .ok () => return result
        | .error error => return { result with outcome := .error error }) .dedicated
      tasks := tasks.push task
    for task in tasks do results := results.push (← Property.Worker.waitTask task)
    start := start + cap
  for (result, index) in results.zipIdx do
    Property.Worker.fold (index + 1) result "Branch" parent
  if let some error := Property.Worker.chooseError results then throw error
  return results.filterMap fun result ↦ match result.outcome with | .ok value => some value | _ => none

def mapConcurrently (f : α → Property β) (values : Array α) : Property (Array β) :=
  runBranches (max 1 values.size) (values.map f)

def forConcurrently (values : Array α) (f : α → Property β) : Property (Array β) :=
  mapConcurrently f values

def mapConcurrently_ (f : α → Property β) (values : Array α) : Property Unit := do
  let _ ← mapConcurrently f values

def forConcurrently_ (values : Array α) (f : α → Property β) : Property Unit :=
  mapConcurrently_ f values

def replicateConcurrently (count : Nat) (action : Property α) : Property (Array α) :=
  runBranches (max 1 count) (Array.replicate count action)

def replicateConcurrently_ (count : Nat) (action : Property α) : Property Unit := do
  let _ ← replicateConcurrently count action

def replicateConcurrentlyBounded (cap count : Nat) (action : Property α) : Property (Array α) :=
  runBranches cap (Array.replicate count action)

def concurrently (left : Property α) (right : Property β) : Property (α × β) := do
  let results : Array (Sum α β) ← runBranches 2 #[Sum.inl <$> left, Sum.inr <$> right]
  match results.toList with
  | [Sum.inl a, Sum.inr b] => return (a, b)
  | _ => throw (.error "Concurrent result shape is inconsistent")

def concurrently_ (left : Property α) (right : Property β) : Property Unit := do
  let _ ← concurrently left right

end Hegel.Property.Branch
