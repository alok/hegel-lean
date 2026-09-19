import Hegel.Gen
import Hegel.Settings
import Hegel.Assertion.IO
import Std.Sync.Mutex

namespace Hegel

inductive Scope where
  | caseSetup | inStep
  deriving BEq, Repr

structure ForkCleanup where
  settled : IO.Ref Bool
  cancel : BaseIO Unit

/-- Per-execution state. Worker streams own their journals, finalizers, and fork registries. -/
structure Property.Context where
  session : Internal.Session.type
  settings : Settings
  journal : IO.Ref (Array Note)
  events : IO.Ref (Array PoolEvent)
  poolLabels : Std.Mutex (Array (Nat × String))
  clock : IO.Ref Nat
  finalizers : IO.Ref (Array (IO Unit))
  cleanupDiagnostics : IO.Ref (Array CleanupDiagnostic)
  forks : IO.Ref (Array ForkCleanup)
  scope : Scope := .caseSetup
  depth : Nat := 0
  cloneDepth : Nat := 0

/-- The property environment can be interpreted in another effect monad. -/
abbrev PropertyT (m : Type → Type) := ReaderT Property.Context m

/-- A property interleaves draws, observations, assertions, and explicit IO. -/
abbrev Property := PropertyT (EIO Abort)

namespace Property

def Context.new (session : Internal.Session.type) (settings : Settings := {}) :
    BaseIO Context := do
  return {
    session, settings, journal := ← IO.mkRef #[], events := ← IO.mkRef #[],
    poolLabels := ← Std.Mutex.new #[],
    clock := ← IO.mkRef 0, finalizers := ← IO.mkRef #[]
    cleanupDiagnostics := ← IO.mkRef #[], forks := ← IO.mkRef #[] }

def getContext : Property Context := read

def getSession : Property Internal.Session.type := return (← getContext).session

def hoist (transform : ∀ {α}, m α → n α) (action : PropertyT m α) : PropertyT n α :=
  fun context ↦ transform (action context)

/-- Draw without recording its representation. Useful for function-valued generators. -/
def draw (gen : Gen α) : Property α := fun context ↦ do
  let result ← (gen context.session).toBaseIO
  let events ← (Internal.drainPoolEvents context.session).adapt (fun e ↦ Abort.error (toString e))
  for event in events do
    let clock ← context.clock.modifyGet fun n ↦ (n, n + 1)
    let operation := match event.kind with
      | 0 => PoolOperation.add
      | 1 => .reuse
      | 2 => .consume
      | _ => .transfer ⟨event.sourcePool, event.sourceIndex⟩
    let labels ← context.poolLabels.atomically get
    let label := (labels.find? (fun entry => entry.1 == event.pool)).map (·.2)
    context.events.modify (·.push { ref := ⟨event.pool, event.index⟩, operation, clock, label })
  match result with
  | .ok value => return value
  | .error e => throw e

/-- Capture the pool choices resolved by this draw, excluding newly registered identities. -/
def drawWithProvenance (gen : Gen α) : Property (α × Array PoolVar) := do
  let context ← getContext
  let start := (← context.events.get).size
  let value ← draw gen
  let events ← context.events.get
  let refs := (events.extract start events.size).filterMap fun event =>
    match event.operation with
    | .reuse | .consume => some event.ref
    | .add | .transfer _ => none
  return (value, refs)

/-- Associate a pool's stable case-local identity with its display name, shared by worker clones. -/
def labelPool (identity : Nat) (label : String) : Property Unit := do
  let context ← getContext
  context.poolLabels.atomically <| modify fun labels =>
    (labels.filter (fun entry => entry.1 != identity)).push (identity, label)

def tick : Property Nat := fun context ↦ context.clock.modifyGet fun n ↦ (n, n + 1)

def note (kind : NoteKind) (text : String) (source : Option SourceLocation := none) :
    Property Unit := do
  let context ← getContext
  let clock ← tick
  context.journal.modify (·.push { kind, text, source, clock, depth := context.depth })

def recordEvent (event : PoolEvent) : Property Unit := do
  let context ← getContext
  let clock ← tick
  context.events.modify (·.push { event with clock })

def annotate (message : String) : Property Unit := note .annotation message

def annotateAt (message : String) (source : SourceLocation) : Property Unit :=
  note .annotation message source

def annotateShow [Repr α] (value : α) : Property Unit := annotate (reprStr value)

def footnote (message : String) : Property Unit := note .footnote message

def nested (action : Property α) : Property α := fun context ↦
  action { context with depth := context.depth + 1 }

def withScope (scope : Scope) (action : Property α) : Property α := fun context ↦
  action { context with scope }

/-- Draw and retain the final counterexample's value in the failure report. -/
def forAll [Repr α] (gen : Gen α) (label : String := "value") : Property α := do
  let (value, refs) ← drawWithProvenance gen
  note (.drawn refs) s!"{label} = {reprStr value}"
  return value

def forAllWithLabel (render : α → String) (label : String) (gen : Gen α) : Property α := do
  let (value, refs) ← drawWithProvenance gen
  note (.drawn refs) s!"{label} = {render value}"
  return value

def forAllWith (render : α → String) (gen : Gen α) : Property α :=
  forAllWithLabel render "value" gen

def forAllSilent (gen : Gen α) : Property α := draw gen

/-- Origins must be stable across draws so Hegel can group and shrink each bug. -/
def failure (origin : String) (message : String := "Assertion failed") : Property α := do
  note (.failure none) message
  throw (.failure origin message)

def failureAt (message : String) (source : SourceLocation) : Property α := do
  note (.failure none) message source
  throw (.failure source.origin message)

def assertThat (condition : Bool) (origin : String) (message : String := "Assertion failed") :
    Property Unit := unless condition do failure origin message

def assertEq [BEq α] [Repr α] (actual expected : α) (origin : String) : Property Unit :=
  assertThat (actual == expected) origin s!"Expected {reprStr expected}, got {reprStr actual}"

def assertNe [BEq α] [Repr α] (actual unexpected : α) (origin : String) : Property Unit :=
  assertThat (actual != unexpected) origin s!"Values must differ: {reprStr actual}"

/-- Evaluate a decidable proposition as a test. Passing is not a proof of universal validity. -/
def assertProp (p : Prop) [Decidable p] (origin : String) : Property Unit :=
  assertThat (decide p) origin

def assume (condition : Bool) : Property Unit := draw (Gen.assume condition)

def discard : Property α := throw .discard

/-- Execute an effect on every replay. The caller must reset mutable state per case. -/
def io (action : IO α) (origin : String := "IO exception") : Property α := do
  if ← IO.checkCanceled then throw (.error "Property cancelled")
  match ← action.toBaseIO with
  | .ok value => return value
  | .error e =>
    if let some assertion := Assertion.IOEnvelope.decode e then
      note (.failure assertion.diff) assertion.message assertion.source
      throw (.failure assertion.source.origin assertion.message)
    else failure origin (toString e)

def forEach [Repr α] (gen : Gen α) (body : α → IO Unit) : Property Unit := do
  io (body (← forAll gen))

def forEachWith (render : α → String) (gen : Gen α) (body : α → IO Unit) : Property Unit := do
  io (body (← forAllWith render gen))

/-- Register a release operation for the current execution, in last-in-first-out order. -/
def registerFinalizer (action : IO Unit) : Property Unit := do
  (← getContext).finalizers.modify (·.push action)

/-- Acquire per-case resources in setup; release them even when the property aborts. -/
def resource (acquire : IO α) (release : α → IO Unit) : Property α := do
  if (← getContext).scope == .inStep then
    throw (.error "Resources must be acquired in case setup, outside rules and invariants")
  let value ← io acquire "resource acquisition"
  registerFinalizer (release value)
  return value

def resource_ (acquire : IO α) (release : α → IO Unit) : Property Unit := do
  let _ ← resource acquire release
  pure ()

/-- Direct the engine toward larger finite scores. -/
def target (score : Float) (label : String := "score") : Property Unit :=
  draw (Gen.native (Internal.target · score label))

/-- Settle structured concurrency before releasing resources, preserving all cleanup attempts. -/
def runInContext (context : Context) (action : Property α) : BaseIO (Except Abort α) := do
  let mut result ← (action context).toBaseIO
  let forks ← context.forks.get
  for fork in forks do
    unless ← fork.settled.get do
      fork.cancel
      fork.settled.set true
      result := .error (.error "Malformed property: a fork was neither joined nor cancelled")
  let finalizers ← context.finalizers.get
  context.finalizers.set #[]
  for release in finalizers.reverse do
    match ← release.toBaseIO with
    | .ok () => pure ()
    | .error error =>
      context.cleanupDiagnostics.modify (·.push { message := toString error })
      if let .ok _ := result then
        result := .error (.error ("Resource cleanup failed: " ++ toString error))
  return result

end Property
end Hegel
