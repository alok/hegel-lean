import Hegel.Property

namespace Hegel

inductive Phase where
  | reuse | generate | target | shrink
  deriving Repr, BEq

def Phase.mask : Phase → UInt32
  | .reuse => 2
  | .generate => 4
  | .target => 8
  | .shrink => 16

structure Settings where
  maxExamples : UInt64 := 100
  seed : Option UInt64 := none
  database : Option System.FilePath := some ".hegel/examples"
  phases : Array Phase := #[.reuse, .generate, .target, .shrink]
  reportMultipleFailures : Bool := true
  /-- Bitmask from libhegel; zero keeps all health checks enabled. -/
  suppressHealthChecks : UInt32 := 0
  deriving Repr

inductive Outcome where
  | passed | failed | error | nondeterministic
  deriving Repr, BEq, Inhabited

inductive CaseStatus where
  | passed | discarded | overrun | failed | error
  deriving Repr, BEq, Inhabited

structure CaseResult where
  status : CaseStatus
  origin : String := ""
  message : String := ""
  annotations : Array String := #[]
  deriving Repr, Inhabited

structure Failure where
  origin : String
  blob : String
  message : String
  annotations : Array String
  deriving Repr, Inhabited

structure Report where
  name : String
  outcome : Outcome
  /-- Body executions during the campaign, including shrinking; excludes final report replay. -/
  evaluations : Nat := 0
  failures : Array Failure := #[]
  message : String := ""
  deriving Repr, Inhabited

def Report.isSuccess (report : Report) : Bool := report.outcome == .passed

def Report.render (report : Report) : String := Id.run do
  let status := match report.outcome with
    | .passed => "PASS"
    | .failed => "FAIL"
    | .error => "ERROR"
    | .nondeterministic => "NONDETERMINISTIC"
  let mut out := s!"{status} {report.name} ({report.evaluations} evaluations)"
  if !report.message.isEmpty then out := out ++ "\n  " ++ report.message
  for failure in report.failures do
    out := out ++ s!"\n  {failure.origin}: {failure.message}"
    for note in failure.annotations do out := out ++ "\n    " ++ note
    if !failure.blob.isEmpty then out := out ++ "\n  Replay blob: " ++ failure.blob
  return out

private def engineIO (action : EIO Internal.EngineError α) : IO α :=
  action.adapt (IO.userError ∘ toString)

private def newSession (name : String) (settings : Settings) : IO Internal.Session.type :=
  engineIO <| Internal.openSession settings.maxExamples (settings.seed.getD 0)
    settings.seed.isSome (settings.database.map toString |>.getD "") name
    settings.reportMultipleFailures (settings.phases.foldl (· ||| ·.mask) 0)
    settings.suppressHealthChecks

private def execute (session : Internal.Session.type) (property : Property Unit) : IO CaseResult := do
  let journal ← IO.mkRef #[]
  let result ← (property (session, journal)).toBaseIO
  let annotations ← journal.get
  let caseResult := match result with
    | .ok () => { status := .passed, annotations }
    | .error .discard => { status := .discarded, annotations }
    | .error .overrun => { status := .overrun, annotations }
    | .error (.failure origin message) => { status := .failed, origin, message, annotations }
    | .error (.error message) => { status := .error, message, annotations }
  let nativeStatus := match caseResult.status with
    | .passed => 0
    | .discarded => 1
    | .overrun | .error => 2
    | .failed => 3
  engineIO (Internal.complete session nativeStatus caseResult.origin)
  return caseResult

/-- Replay a recorded choice sequence once, returning observations from that exact execution. -/
def replay (blob : String) (property : Property Unit) (settings : Settings := {}) : IO CaseResult := do
  let session ← newSession "replay" { settings with database := none }
  try
    engineIO (Internal.replay session blob)
    execute session property
  finally engineIO (Internal.close session)

/-- Run and shrink a property. Engine errors and failed health checks never count as passes. -/
def check (name : String) (property : Property Unit) (settings : Settings := {}) : IO Report := do
  try
    let session ← newSession name settings
    try
      let mut evaluations := 0
      while ← engineIO (Internal.next session) do
        let result ← execute session property
        evaluations := evaluations + 1
        if result.status == .error then
          return { name, outcome := .error, evaluations, message := result.message }
      let result ← engineIO (Internal.result session)
      let mut outcome := match result.status with
        | 0 => Outcome.passed
        | 1 => .failed
        | 3 => .nondeterministic
        | _ => .error
      let mut failures := #[]
      let mut message := result.message
      for (origin, blob) in result.failures do
        if blob.isEmpty then
          failures := failures.push { origin, blob, message := "No replay blob", annotations := #[] }
        else
          engineIO (Internal.replay session blob)
          let rerun ← execute session property
          if rerun.status != .failed || rerun.origin != origin then
            outcome := .error
            message := s!"Counterexample did not reproduce its failure origin: {origin}"
          failures := failures.push {
            origin, blob
            message := rerun.message
            annotations := rerun.annotations
          }
      return { name, outcome, evaluations, failures, message }
    finally engineIO (Internal.close session)
  catch e => return { name, outcome := .error, message := toString e }

/-- Print a report and raise an IO error unless the property passed. -/
def check! (name : String) (property : Property Unit) (settings : Settings := {}) : IO Unit := do
  let report ← check name property settings
  IO.println report.render
  unless report.isSuccess do throw (IO.userError s!"Property failed: {name}")

structure Test where
  name : String
  property : Property Unit
  settings : Settings := {}

/-- Run all named properties and return an exit code suitable for `main` or `lake test`. -/
def runTests (tests : Array Test) : IO UInt32 := do
  let mut passed := true
  for test in tests do
    let report ← check test.name test.property test.settings
    IO.println report.render
    passed := passed && report.isSuccess
  return if passed then 0 else 1

def engineVersion : IO String := engineIO Internal.version

end Hegel
