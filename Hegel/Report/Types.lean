import Hegel.Diff

namespace Hegel

/-- One-based positions with portable module identity for assertion origins. -/
structure SourceLocation where
  file : String
  moduleName : String := ""
  line : Nat
  column : Nat := 1
  endLine : Nat := line
  endColumn : Nat := column
  deriving Repr, BEq, Inhabited

def SourceLocation.render (source : SourceLocation) : String :=
  s!"{source.file}:{source.line}:{source.column}"

/-- Stable across generated inputs; messages and values never participate in grouping. -/
def SourceLocation.origin (source : SourceLocation) (kind : String := "assertion") : String :=
  let identity := if source.moduleName.isEmpty then source.file else source.moduleName
  s!"{kind} at {identity}:{source.line}:{source.column}"

structure Diagnostic where
  context : String
  detail : String
  values : Array (String × String) := #[]
  source : Option SourceLocation := none
  deriving Repr, BEq, Inhabited

def Diagnostic.render (diagnostic : Diagnostic) : String :=
  diagnostic.context ++ ": " ++ diagnostic.detail ++
    String.join (diagnostic.values.toList.map fun (name, value) => s!"\n  {name} = {value}") ++
    (diagnostic.source.map ("\n  at " ++ ·.render)).getD ""

structure PoolVar where
  pool : Nat
  index : Nat
  deriving Repr, BEq, Inhabited

inductive NoteKind where
  | drawn (variables : Array PoolVar := #[])
  | annotation | response | footnote
  | stepHeader (index : Nat) (rule : String)
  | failure (diff : Option Diff := none)
  | branchHeader (index : Nat)
  | branchFailure (diff : Option Diff := none)
  | stepOrigin (round worker : Nat) (group : Option String)
  | roundBoundary (step round : Nat)
  deriving Repr, BEq, Inhabited

structure Note where
  kind : NoteKind := .annotation
  text : String
  source : Option SourceLocation := none
  depth : Nat := 0
  clock : Nat := 0
  deriving Repr, BEq, Inhabited

def Note.isDrawn (note : Note) : Bool := match note.kind with
  | .drawn _ => true
  | _ => false

def Note.isFailure (note : Note) : Bool := match note.kind with
  | .failure _ | .branchFailure _ => true
  | _ => false

inductive PoolOperation where
  | add | reuse | consume | transfer (source : PoolVar)
  deriving Repr, BEq, Inhabited

structure PoolEvent where
  ref : PoolVar
  operation : PoolOperation
  clock : Nat
  label : Option String := none
  deriving Repr, BEq, Inhabited

structure TraceOrigin where
  round : Nat
  worker : Nat
  group : Option String := none
  deriving Repr, BEq, Inhabited

structure TraceIdentity where
  ref : PoolVar
  ordinal : Nat
  label : Option String := none
  lineage : Option PoolVar := none
  deriving Repr, BEq, Inhabited

structure TraceStep where
  index : Nat
  rule : String
  notes : Array Note := #[]
  touches : Array PoolEvent := #[]
  freeDraws : Array String := #[]
  response : Option String := none
  failed : Bool := false
  origin : Option TraceOrigin := none
  deriving Repr, BEq, Inhabited

private def TraceStep.withTouches (step : TraceStep) (touches : Array PoolEvent) : TraceStep :=
  let freeDraws := step.notes.filterMap fun note => match note.kind with
    | .drawn refs =>
      if refs.size == 1 && touches.any (·.ref == refs[0]!) then none else some note.text
    | _ => none
  { step with touches, freeDraws }

structure Trace where
  steps : Array TraceStep := #[]
  events : Array PoolEvent := #[]
  identities : Array TraceIdentity := #[]
  failureStep : Option Nat := none
  deriving Repr, BEq, Inhabited

inductive ReplayReason where
  | unexpectedSuccess | unexpectedDiscard | exhaustedChoices | missingReplayData
  | changedOrigin (origin : String)
  | invalidReplayBlob (detail : String)
  | reconstructionAborted (detail : String)
  | incompatibleVersions (tokenVersion engineVersion : String)
  deriving Repr, BEq, Inhabited

def ReplayReason.render : ReplayReason → String
  | .unexpectedSuccess => "the replay passed instead of failing"
  | .unexpectedDiscard => "the replay discarded instead of failing"
  | .exhaustedChoices => "the replay exhausted its choices"
  | .missingReplayData => "the engine exposed no replay data"
  | .changedOrigin origin => "replay failed at a different origin: " ++ origin
  | .invalidReplayBlob detail => "the engine rejected the replay blob: " ++ detail
  | .reconstructionAborted detail => "reconstruction aborted: " ++ detail
  | .incompatibleVersions tokenVersion engineVersion =>
    s!"token uses libhegel {tokenVersion}, but this run uses {engineVersion}"

inductive SkipReason where
  | afterCleanupFailure | afterReconstructionAbort
  deriving Repr, BEq, Inhabited

structure CleanupDiagnostic where
  message : String
  deriving Repr, BEq, Inhabited

structure FailureEvidence where
  message : String
  notes : Array Note := #[]
  events : Array PoolEvent := #[]
  source : Option SourceLocation := none
  diff : Option Diff := none
  deriving Repr, BEq, Inhabited

inductive FailureEvidenceStatus where
  | reconstructed (evidence : FailureEvidence)
  | diverged (reason : ReplayReason)
  | skipped (reason : SkipReason)
  | observed (evidence : FailureEvidence)
  deriving Repr, BEq, Inhabited

structure ReplayStats where
  attempted : Nat := 0
  valid : Nat := 0
  invalid : Nat := 0
  exhausted : Nat := 0
  reproduced : Nat := 0
  deriving Repr, BEq, Inhabited

structure Stats where
  valid : Nat := 0
  invalid : Nat := 0
  overruns : Nat := 0
  replay : Option ReplayStats := none
  deriving Repr, BEq, Inhabited

inductive Reproduction where
  | stored (key : String)
  | unstored | unreproducible
  deriving Repr, BEq, Inhabited

/-- Recover stateful step boundaries and join notes with pool activity by their shared clock. -/
def Trace.build (notes : Array Note) (events : Array PoolEvent) : Trace := Id.run do
  let mut steps : Array TraceStep := #[]
  let mut current : TraceStep := { index := 0, rule := "<initial>" }
  let mut start := 0
  for note in notes do
    let header := match note.kind with
      | .stepHeader index rule => some (index, rule)
      | .roundBoundary index round => some (index, s!"round {round} invariant check")
      | _ => none
    if let some (index, rule) := header then
      current := current.withTouches (events.filter fun e =>
        e.clock >= start && e.clock < note.clock)
      if !current.notes.isEmpty || !current.touches.isEmpty then steps := steps.push current
      current := { index, rule }
      start := note.clock
    current := { current with
      notes := current.notes.push note
      failed := current.failed || note.isFailure }
    if note.kind == .response then current := { current with response := some note.text }
    if let .stepOrigin round worker group := note.kind then
      current := { current with origin := some { round, worker, group } }
  current := current.withTouches (events.filter (·.clock >= start))
  if !current.notes.isEmpty || !current.touches.isEmpty then steps := steps.push current
  let mut identities : Array TraceIdentity := #[]
  for event in events do
    if !(identities.any (·.ref == event.ref)) then
      let ordinal := (identities.filter (·.ref.pool == event.ref.pool)).size + 1
      let lineage := match event.operation with
        | .transfer source => some source
        | _ => none
      identities := identities.push { ref := event.ref, ordinal, label := event.label, lineage }
  return { steps, events, identities, failureStep := (steps.find? (·.failed)).map (·.index) }

/-- Follow transfer identities with cycle protection; malformed external traces terminate. -/
def Trace.root (trace : Trace) (ref : PoolVar) : PoolVar := Id.run do
  let mut current := ref
  let mut seen : Array PoolVar := #[]
  for _ in [:trace.events.size + 1] do
    if seen.contains current then return current
    seen := seen.push current
    match trace.events.find? (fun event => event.ref == current) with
    | some { operation := .transfer source, .. } => current := source
    | _ => return current
  return current

def Trace.step (trace : Trace) (index : Nat) : Option TraceStep :=
  trace.steps.find? (·.index == index)

def Trace.identity (trace : Trace) (ref : PoolVar) : Option TraceIdentity :=
  trace.identities.find? (·.ref == ref)

namespace Journal

/-- Render notes in causal order, preserving nesting and moving footnotes to the end. -/
def render (notes : Array Note) : String := Id.run do
  let mut lines : Array String := #[]
  let mut counters : Array Nat := #[]
  for note in notes.filter (·.kind != .footnote) do
    counters := counters.extract 0 (note.depth + 1)
    while counters.size <= note.depth do counters := counters.push 0
    let padding := String.ofList (List.replicate (2 * note.depth) ' ')
    let mut text := note.text
    if note.isDrawn then
      let number := counters[note.depth]! + 1
      counters := counters.set! note.depth number
      text := s!"Draw {number}: {text}"
    if note.isFailure then text := "FAIL: " ++ text
    lines := lines.push (padding ++ text)
    match note.kind with
    | .failure (some diff) | .branchFailure (some diff) =>
      for line in (renderDiff diff).splitOn "\n" do lines := lines.push (padding ++ "  " ++ line)
    | _ => pure ()
    if let some source := note.source then lines := lines.push (padding ++ "  at " ++ source.render)
  for note in notes.filter (·.kind == .footnote) do lines := lines.push note.text
  return String.intercalate "\n" lines.toList

/-- Source listings are an optional enhancement: missing files retain the portable location. -/
def renderSource (source : SourceLocation) (context : Nat := 2) : IO String := do
  try
    let content ← IO.FS.readFile source.file
    let lines := (content.splitOn "\n").toArray
    let first := source.line - 1 - context
    let last := min lines.size (source.endLine + context)
    let mut out := "at " ++ source.render
    for index in [first:last] do
      out := out ++ s!"\n{index + 1} | {lines[index]!}"
      if index + 1 == source.line then
        out := out ++ "\n  | " ++ String.ofList (List.replicate (source.column - 1) ' ') ++ "^"
    return out
  catch _ => return "at " ++ source.render

end Journal
end Hegel
