import Hegel.Property
import Hegel.Report.Style

namespace Hegel

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
  notes : Array Note := #[]
  events : Array PoolEvent := #[]
  cleanupDiagnostics : Array CleanupDiagnostic := #[]
  deriving Repr, Inhabited

def CaseResult.toEvidence (result : CaseResult) : FailureEvidence :=
  let note := result.notes.find? fun note =>
    note.isFailure && (note.source.map (·.origin == result.origin) |>.getD true)
  let diff := note.bind fun note => match note.kind with
    | .failure diff | .branchFailure diff => diff
    | _ => none
  {
    message := result.message, notes := result.notes, events := result.events
    source := note.bind (·.source), diff }

def CaseResult.replayReason (result : CaseResult) (expectedOrigin : String) : Option ReplayReason :=
  match result.status with
  | .passed => some .unexpectedSuccess
  | .discarded => some .unexpectedDiscard
  | .overrun => some .exhaustedChoices
  | .error => some (.reconstructionAborted result.message)
  | .failed => if result.origin == expectedOrigin then none else some (.changedOrigin result.origin)

structure Failure where
  origin : String
  blob : String
  message : String
  annotations : Array String
  evidence : FailureEvidenceStatus := .diverged .missingReplayData
  notes : Array Note := #[]
  trace : Trace := {}
  cleanupDiagnostics : Array CleanupDiagnostic := #[]
  deriving Repr, Inhabited

structure Report where
  name : String
  outcome : Outcome
  /-- Body executions during the campaign, including shrinking; excludes final report replay. -/
  evaluations : Nat := 0
  failures : Array Failure := #[]
  message : String := ""
  stats : Stats := {}
  engineOutput : String := ""
  cleanupDiagnostics : Array CleanupDiagnostic := #[]
  reproduction : Reproduction := .unstored
  deriving Repr, Inhabited

def Report.isSuccess (report : Report) : Bool := report.outcome == .passed

private def Report.renderBody (report : Report) (style : ReportStyle) : String := Id.run do
  let style := { style with color := false }
  let status := match report.outcome with
    | .passed => "PASS"
    | .failed => "FAIL"
    | .error => "ERROR"
    | .nondeterministic => "NONDETERMINISTIC"
  let mut out := s!"{status} {report.name} ({report.evaluations} evaluations)"
  if !report.message.isEmpty then out := out ++ "\n  " ++ report.message
  for failure in report.failures do
    out := out ++ s!"\n  {failure.origin}: {failure.message}"
    if failure.trace.steps.any (·.index != 0) then
      out := out ++ "\n" ++ Trace.renderWith style failure.trace
    if failure.notes.isEmpty then
      for note in failure.annotations do out := out ++ "\n    " ++ note
    else out := out ++ "\n" ++ Journal.renderWith style failure.notes
    match failure.evidence with
    | .diverged reason => out := out ++ "\n  Replay diverged: " ++ reason.render
    | .skipped .afterCleanupFailure =>
      out := out ++ "\n  Reconstruction skipped after an earlier cleanup failure"
    | .skipped .afterReconstructionAbort =>
      out := out ++ "\n  Reconstruction skipped after an earlier reconstruction error"
    | .observed _ => out := out ++ "\n  Observed during execution; no deterministic reconstruction"
    | .reconstructed _ => pure ()
    if !failure.blob.isEmpty then out := out ++ "\n  Replay blob: " ++ failure.blob
  for diagnostic in report.cleanupDiagnostics do
    out := out ++ "\n  Cleanup failed: " ++ diagnostic.message
  if !report.engineOutput.isEmpty then out := out ++ "\n" ++ report.engineOutput
  match report.reproduction with
  | .stored key => out := out ++ "\n  " ++ style.phrases.stored key
  | .unreproducible => out := out ++ "\n  " ++ style.phrases.unreproducible
  | .unstored => pure ()
  return out

def Report.render (report : Report) : String := report.renderBody {}

def Report.renderAnsi (report : Report) : String :=
  ReportStyle.finish { color := true } report.render

def Report.renderRichWith (report : Report) (style : ReportStyle) : IO String := do
  let style ← style.resolve
  let mut text := report.renderBody style
  let mut sources : Array SourceLocation := #[]
  for failure in report.failures do
    for note in failure.notes do
      if note.isFailure || note.isDrawn then
        if let some source := note.source then
          if !sources.contains source then
            sources := sources.push source
            let listing ← Journal.renderSource source style.sourceContext
            text := text ++ "\n" ++ ReportStyle.limitLines style.maxSourceLines listing
  return style.finish text

def Report.renderRich (report : Report) : IO String := report.renderRichWith {}

def Report.renderRichAnsiWith (report : Report) (style : ReportStyle) : IO String :=
  report.renderRichWith { style with color := true }

def Report.renderRichAnsi (report : Report) : IO String := report.renderRichAnsiWith {}

def Report.renderAuto (report : Report) : IO String := do
  let noColor ← IO.getEnv "NO_COLOR"
  let term ← IO.getEnv "TERM"
  report.renderRichWith {
    color := noColor.isNone && term.isSome && term != some "dumb"
    preference := .auto }

/-- Raise an IO error for failures, inconclusive campaigns, and execution errors. -/
def Report.throwOnFailure (report : Report) : IO Unit :=
  unless report.isSuccess do throw (IO.userError report.render)

private def engineIO (action : EIO Internal.EngineError α) : IO α :=
  action.adapt (IO.userError ∘ toString)

private def newSession (name : String) (settings : Settings) : IO Internal.Session.type := do
  let session ← engineIO <| Internal.openSession settings.maxExamples (settings.seed.getD 0)
    settings.seed.isSome (settings.database.map toString |>.getD "") name
    settings.reportMultipleFailures settings.phaseMask settings.healthCheckMask
  try
    engineIO (settings.configure session)
    engineIO (Internal.startRun session)
    return session
  catch e =>
    engineIO (Internal.close session)
    throw e

private def execute (session : Internal.Session.type) (property : Property Unit)
    (settings : Settings) : IO CaseResult := do
  let context ← Property.Context.new session settings
  let result ← Property.runInContext context property
  let notes ← context.journal.get
  let events ← context.events.get
  let cleanupDiagnostics ← context.cleanupDiagnostics.get
  let annotations := (notes.filter fun note ↦ !note.isFailure).map (·.text)
  let caseResult : CaseResult := match result with
    | .ok () => { status := .passed, annotations, notes, events }
    | .error .discard => { status := .discarded, annotations, notes, events }
    | .error .overrun => { status := .overrun, annotations, notes, events }
    | .error (.failure origin message) =>
      { status := .failed, origin, message, annotations, notes, events }
    | .error (.error message) => { status := .error, message, annotations, notes, events }
    | .error _ => {
        status := .error, message := "Recursive retry escaped its generator"
        annotations, notes, events }
  let nativeStatus := match caseResult.status with
    | .passed => 0
    | .discarded => 1
    | .overrun | .error => 2
    | .failed => 3
  engineIO (Internal.complete session nativeStatus caseResult.origin)
  return { caseResult with cleanupDiagnostics }

/-- Replay a recorded choice sequence once, returning observations from that exact execution. -/
def replay (blob : String) (property : Property Unit) (settings : Settings := {}) :
    IO CaseResult := do
  let session ← newSession "replay" { settings with database := none }
  try
    engineIO (Internal.replay session blob)
    execute session property settings
  finally engineIO (Internal.close session)

/-- Run and shrink a property. Engine errors and failed health checks never count as passes. -/
def check (name : String) (property : Property Unit) (settings : Settings := {}) : IO Report := do
  try
    let session ← newSession name settings
    try
      let mut evaluations := 0
      let mut stats : Stats := {}
      let mut observations : Array CaseResult := #[]
      while ← engineIO (Internal.next session) do
        let result ← execute session property settings
        evaluations := evaluations + 1
        match result.status with
        | .passed => stats := { stats with valid := stats.valid + 1 }
        | .discarded => stats := { stats with invalid := stats.invalid + 1 }
        | .overrun => stats := { stats with overruns := stats.overruns + 1 }
        | .failed =>
          observations := observations.filter (·.origin != result.origin) |>.push result
        | .error => pure ()
        if !result.cleanupDiagnostics.isEmpty then
          let failures := if result.status == .failed then #[{
            origin := result.origin, blob := "", message := result.message
            annotations := result.annotations, notes := result.notes
            trace := Trace.build result.notes result.events
            cleanupDiagnostics := result.cleanupDiagnostics
            evidence := .skipped .afterCleanupFailure : Failure }] else #[]
          return {
            name, outcome := .error, evaluations, stats, failures
            cleanupDiagnostics := result.cleanupDiagnostics
            message := "Resource cleanup failed; campaign stopped before further execution" }
        if result.status == .error then
          return { name, outcome := .error, evaluations, stats, message := result.message }
      let result ← engineIO (Internal.result session)
      let mut outcome := match result.status with
        | 0 => Outcome.passed
        | 1 => .failed
        | 3 => .nondeterministic
        | _ => .error
      let mut failures := #[]
      let mut message := result.message
      let mut cleanupDiagnostics := #[]
      let mut skip : Option SkipReason := none
      if outcome == .passed && stats.valid == 0 then
        outcome := .error
        message := "No valid examples completed; the campaign cannot establish a passing result"
      for (origin, blob) in result.failures do
        if let some reason := skip then
          failures := failures.push {
            origin, blob, message := "Reconstruction was not attempted", annotations := #[]
            evidence := .skipped reason }
        else if blob.isEmpty then
          let observed := observations.find? (·.origin == origin)
          let evidence := observed.map (·.toEvidence) |>.getD { message := "No replay blob" }
          let status := if result.status == 3 && observed.isSome then
            FailureEvidenceStatus.observed evidence else .diverged .missingReplayData
          if !(result.status == 3 && observed.isSome) then
            outcome := .error
            message := "A deterministic engine failure had no replay data"
          failures := failures.push {
            origin, blob, message := evidence.message
            annotations := observed.map (·.annotations) |>.getD #[]
            notes := evidence.notes, trace := Trace.build evidence.notes evidence.events
            evidence := status }
        else
          let initialized ← (Internal.replay session blob).toBaseIO
          match initialized with
          | .error error =>
            outcome := .error
            message := "The engine rejected a recorded replay blob"
            failures := failures.push {
              origin, blob, message := toString error, annotations := #[]
              evidence := .diverged (.invalidReplayBlob (toString error)) }
          | .ok () =>
            let replayed ← (execute session property settings).toBaseIO
            match replayed with
            | .error error =>
              outcome := .error
              message := "Reconstruction aborted before producing a test result"
              skip := some .afterReconstructionAbort
              failures := failures.push {
                origin, blob, message := toString error, annotations := #[]
                evidence := .diverged (.reconstructionAborted (toString error)) }
            | .ok rerun =>
              let reason := rerun.replayReason origin
              if let some reason := reason then
                outcome := .error
                message := reason.render
                if rerun.status == .error then skip := some .afterReconstructionAbort
              if !rerun.cleanupDiagnostics.isEmpty then
                cleanupDiagnostics := cleanupDiagnostics ++ rerun.cleanupDiagnostics
                outcome := .error
                message := "Reconstruction cleanup failed; remaining failures were not replayed"
                skip := some .afterCleanupFailure
              failures := failures.push {
                origin, blob, message := rerun.message, annotations := rerun.annotations
                notes := rerun.notes, trace := Trace.build rerun.notes rerun.events
                cleanupDiagnostics := rerun.cleanupDiagnostics
                evidence := match reason with
                  | some reason => .diverged reason
                  | none => .reconstructed rerun.toEvidence }
      let engineOutput ← engineIO (Internal.output session)
      let reproduction := if result.status == 3 then Reproduction.unreproducible
        else if result.status == 1 &&
            !(settings.database.map toString |>.getD "").isEmpty then
          .stored (settings.databaseKey.getD name) else .unstored
      return {
        name, outcome, evaluations, failures, message, stats, engineOutput
        cleanupDiagnostics, reproduction }
    finally engineIO (Internal.close session)
  catch e => return { name, outcome := .error, message := toString e }

/-- Print a report and raise an IO error unless the property passed. -/
def check! (name : String) (property : Property Unit) (settings : Settings := {}) : IO Unit := do
  let report ← check name property settings
  IO.println report.render
  report.throwOnFailure

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

/-- Draw from one generation-only campaign. Exhausted finite spaces can yield fewer values. -/
def samples (count : Nat) (gen : Gen α) (settings : Settings := {}) : IO (Array α) := do
  IO.ofExcept (settings.validate.mapError toString)
  if count >= 2 ^ 64 then throw (IO.userError "Sample count exceeds UInt64")
  if count == 0 then return #[]
  let config := { settings with
    maxExamples := count.toUInt64, database := none, databaseKey := none
    phases := #[.generate] }
  let session ← newSession "samples" config
  try
    let mut values := #[]
    while ← engineIO (Internal.next session) do
      let observed ← IO.mkRef (none : Option α)
      let result ← execute session (do observed.set (some (← Property.draw gen))) config
      match result.status with
      | .passed =>
        let some value ← observed.get | throw (IO.userError "Sampling produced no value")
        values := values.push value
      | .discarded | .overrun => pure ()
      | .failed | .error => throw (IO.userError result.message)
    let result ← engineIO (Internal.result session)
    if result.status != 0 then throw (IO.userError result.message)
    return values
  finally engineIO (Internal.close session)

/-- Draw exactly one case. A discard or exhausted choice budget raises an IO error. -/
def sample (gen : Gen α) (settings : Settings := {}) : IO α := do
  let config := { settings with
    maxExamples := 1, database := none, databaseKey := none, phases := #[.generate] }
  let session ← newSession "sample" config
  try
    unless ← engineIO (Internal.next session) do
      throw (IO.userError "sample: engine produced no test case")
    let observed ← IO.mkRef (none : Option α)
    let result ← execute session (do observed.set (some (← Property.draw gen))) config
    match result.status with
    | .passed =>
      let some value ← observed.get | throw (IO.userError "Sampling produced no value")
      return value
    | .discarded => throw (IO.userError "sample: generator discarded its only case")
    | .overrun => throw (IO.userError "sample: choice budget exhausted")
    | .failed | .error => throw (IO.userError result.message)
  finally engineIO (Internal.close session)

def prop [Repr α] (gen : Gen α) (body : α → IO Unit) (name : String := "property") : IO Unit :=
  check! name (Property.forEach gen body)

def engineVersion : IO String := engineIO Internal.version

end Hegel
