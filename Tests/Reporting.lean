import Hegel.Assertion
import Hegel.Runner
import Hegel.Report.Style
import Hegel.Pool

namespace Tests.Reporting
open Hegel Hegel.Property

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def sourceFailure : Property Unit := do
  let n ← forAll! (Gen.nat 0 20)
  assertEq! n (n + 1)

private def otherSourceFailure : Property Unit := do
  assert! false because "second site"

private def ioSourceFailure : Property Unit :=
  Property.forEach (Gen.nat 0 20) fun n => do
    assertEq! n (n + 1)

private def drawSequence (settings : Settings) : IO (Array Int) := do
  let engineIO {α} (action : EIO Internal.EngineError α) : IO α :=
    action.adapt (IO.userError ∘ toString)
  let session ← engineIO <| Internal.openSession settings.maxExamples
    (settings.seed.getD 0) settings.seed.isSome "" "fallback-key"
    settings.reportMultipleFailures settings.phaseMask settings.healthCheckMask
  try
    engineIO (Settings.configure session settings)
    engineIO (Internal.startRun session)
    let mut values := #[]
    while ← engineIO (Internal.next session) do
      values := values.push (← engineIO (Internal.integer session 0 1000000))
      engineIO (Internal.complete session 0 "")
    return values
  finally engineIO (Internal.close session)

/-- The counter is observational until after a separately measured deterministic campaign. -/
private def campaignMutation (counter : IO.Ref Nat) (cutoff mode : Nat) : Property Unit := do
  let execution ← counter.modifyGet fun n => (n + 1, n + 1)
  let flag ← draw Gen.bool
  if execution > cutoff then
    match mode with
    | 1 => return ()
    | 2 => Property.discard
    | 3 => throw .overrun
    | 4 =>
      Property.registerFinalizer (throw (IO.userError "cleanup-one"))
      Property.registerFinalizer (throw (IO.userError "cleanup-two"))
    | 5 => Property.failure "changed-origin"
    | 6 => throw (.error "reconstruction interrupted")
    | _ => pure ()
  Property.failure (if flag then "mutation/true" else "mutation/false")

private def reconstructionTests (settings : Settings) : IO Unit := do
  let counter ← IO.mkRef 0
  let baseline ← check "reconstruction baseline" (campaignMutation counter 0 0) settings
  require (baseline.outcome == .failed && baseline.failures.size == 2) baseline.render
  require ((← counter.get) == baseline.evaluations + 2) "baseline reconstruction executions"
  for mode in [1:7] do
    counter.set 0
    let report ← check "reconstruction mutation"
      (campaignMutation counter baseline.evaluations mode) settings
    require (report.outcome == .error && report.failures.size == 2) report.render
    require (report.evaluations == baseline.evaluations) "mutation must affect only reconstruction"
    let first := report.failures[0]!
    if mode == 4 then
      require (first.cleanupDiagnostics.map (·.message) == #["cleanup-two", "cleanup-one"])
        "every failing finalizer retained in reverse release order"
      require (report.cleanupDiagnostics == first.cleanupDiagnostics)
        "report retains final reconstruction cleanup failures"
      require (match report.failures[1]!.evidence with
        | .skipped .afterCleanupFailure => true | _ => false)
        "later reconstruction must stop after cleanup failure"
      require ((← counter.get) == baseline.evaluations + 1) "unsafe replay was not executed"
    else
      let expected := match mode with
        | 1 => ReplayReason.unexpectedSuccess
        | 2 => .unexpectedDiscard
        | 3 => .exhaustedChoices
        | 5 => .changedOrigin "changed-origin"
        | _ => .reconstructionAborted "reconstruction interrupted"
      require (match first.evidence with
        | .diverged actual => actual == expected | _ => false)
        s!"divergence must remain explicit: {reprStr first.evidence}"
      if mode == 6 then
        require (match report.failures[1]!.evidence with
          | .skipped .afterReconstructionAbort => true | _ => false)
          "later reconstruction must stop after execution error"
        require ((← counter.get) == baseline.evaluations + 1) "aborted replay was not continued"
      else
        require ((← counter.get) == baseline.evaluations + 2) "all safe replay attempts retained"
  IO.println "ok: reporting/reconstruction divergence cleanup and skipped evidence"

private def provenanceTests (settings : Settings) : IO Unit := do
  let property : Property Unit := do
    let source ← Pool.named "open"
    let destination ← Pool.named "closed"
    Pool.add source (17 : Nat)
    let _ ← forAll source.reuse
    let _ ← forAll! (source.transfer destination)
    let _ ← forAllWith (fun values => reprStr values) (Gen.pair destination.reuse destination.reuse)
    let _ ← forAllSilent destination.reuse
    let _ ← forAll (pure (42 : Nat))
    failure "provenance"
  let report ← check "pool draw provenance" property settings
  require (report.outcome == .failed && report.failures.size == 1) report.render
  let recorded := report.failures[0]!
  let provenance := recorded.notes.filterMap fun note => match note.kind with
    | .drawn refs => some refs
    | _ => none
  require (provenance.map (·.size) == #[1, 1, 2, 0])
    "pool draw references bind to each draw; silent provenance does not leak"
  require (provenance[0]! == provenance[1]!) "transfer draw retains consumed source identity"
  require (provenance[2]![0]! == provenance[2]![1]!)
    "composite draws retain every resolved pool reference"
  require ((recorded.trace.step 0 |>.map (·.freeDraws.size)) == some 2)
    "only composite and non-pool draws remain free trace details"
  let replayed ← replay recorded.blob property settings
  require (replayed.notes == recorded.notes) "draw provenance survives exact replay"
  IO.println "ok: reporting/pool draw provenance and free values"

def run : IO Unit := do
  require (({ } : Settings).validate.isOk) "default settings validation"
  require (!({ statefulStepCount := 0 } : Settings).validate.isOk) "zero stateful steps"
  require (!({ statefulStepCount := UInt64.size } : Settings).validate.isOk) "step overflow"
  require (!({ suppressHealthChecks := 16 } : Settings).validate.isOk) "unknown health bit"
  require (!({ databaseKey := some "a\x00b" } : Settings).validate.isOk) "NUL database key"
  require (!({ database := some "a\x00b" } : Settings).validate.isOk) "NUL database path"
  let healthSettings : Settings := {
    suppressHealthChecks := 1, suppressHealthCheck := #[.tooSlow] }
  require (healthSettings.healthCheckMask == 3) "health check masks combine"
  require (({ } : Settings).phaseMask == 31) "all five phase flags"
  require (({ phases := #[.reuse, .reuse, .shrink] } : Settings).phaseMask == 18)
    "duplicate phases do not double-count"
  require (Verbosity.quiet.code == 1 && Verbosity.debug.code == 3) "verbosity codes"
  require (Backend.auto.code == 0 && Backend.urandom.code == 2) "backend codes"
  IO.println "ok: reporting/settings validation and enum masks"

  let deterministic : Settings := {
    maxExamples := 20, database := none, databaseKey := some "reporting-sequence",
    derandomize := true, phases := #[.generate] }
  let first ← drawSequence deterministic
  require (first.size == 20) "configuration applied test count"
  require ((← drawSequence deterministic) == first) "derandomization must preserve all choices"
  let different ← drawSequence { deterministic with databaseKey := some "another-sequence" }
  require (different != first) "different keys must produce different deterministic streams"
  let seeded := { deterministic with seed := some 713 }
  require ((← drawSequence seeded) == (← drawSequence { seeded with derandomize := false }))
    "explicit seed must take precedence over derandomization"
  IO.println "ok: reporting/native deterministic settings"

  require (diffLines "a\nb\nc" "a\nd\nc" ==
    #[.same "a", .removed "b", .added "d", .same "c"]) "diff preserves common context"
  require (diffLines "a\nb" "a" == #[.same "a", .removed "b"]) "diff nonoverlapping suffix"
  require (diffLines "" "" == #[.same ""]) "empty diff"
  let some structural := diffShown "{ x := [1, 2], y := 3 }" "{ x := [1, 4], y := 3 }"
    | throw (IO.userError "structural diff parse failed")
  require (structural.any (fun line => line == .same "  y := 3"))
    "unchanged record field should remain context"
  require ((diffShown "[\"[x],\\\"\", 2]" "[\"[x],\\\"\", 3]").isSome)
    "quoted bracket and escaped quote"
  require ((diffShown "[1, 2" "[1, 3]").isNone) "malformed repr must use line fallback"
  require ((renderDiff #[.removed "old", .added "new"]) == "- old\n+ new") "diff rendering"
  IO.println "ok: reporting/structural and line differences"

  let source : SourceLocation := { file := "missing-file.lean", line := 7, column := 3 }
  require (source.origin == "assertion at missing-file.lean:7:3") "stable callsite origin"
  let portable := { source with moduleName := "Project.Example" }
  require (portable.origin == ({ portable with file := "/different/checkout.lean" }).origin)
    "module origins must survive different checkouts"
  require ((← Journal.renderSource source) == "at missing-file.lean:7:3")
    "unavailable source fallback"
  let notes : Array Note := #[
    { kind := .footnote, text := "footer", clock := 0 },
    { kind := .stepHeader 1 "write", text := "Step 1: write", clock := 1 },
    { kind := .drawn #[], text := "10", depth := 1, clock := 2 },
    { kind := .response, text := "written", depth := 1, clock := 3 },
    { kind := .stepHeader 2 "read", text := "Step 2: read", clock := 5 },
    { kind := .drawn #[], text := "20", depth := 1, clock := 6 },
    { kind := .failure none, text := "mismatch", depth := 1, clock := 7 }]
  let events : Array PoolEvent := #[
    { ref := ⟨0, 0⟩, operation := .add, clock := 4 },
    { ref := ⟨1, 0⟩, operation := .transfer ⟨0, 0⟩, clock := 8 }]
  let trace := Trace.build notes events
  require ((trace.step 1 |>.map (·.touches.size) |>.getD 0) == 1) "trace event clock boundary"
  require (trace.step 2 |>.map (·.failed) |>.getD false) "trace failed step"
  require (trace.root ⟨1, 0⟩ == ⟨0, 0⟩) "trace follows transferred pool identity"
  let boundaryTrace := Trace.build #[
    { kind := .stepHeader 1 "worker", text := "worker", clock := 0 },
    { kind := .roundBoundary 2 1, text := "join", clock := 1 },
    { kind := .failure none, text := "invariant", clock := 2 }] #[]
  require (boundaryTrace.failureStep == some 2 &&
    (boundaryTrace.step 2 |>.map (·.rule)) == some "round 1 invariant check")
    "joined invariant failure belongs to its own round boundary"
  let rendered := Journal.render notes
  require (rendered.endsWith "footer") "footnotes move after the journal"
  require ((rendered.splitOn "Draw 1:").length == 3) "draw numbering restarts for each step"
  let ascii := ReportStyle.clean .ascii "λ\x00é😀"
  require (ascii.toList.all (·.toNat < 128)) "ASCII preference covers every rendered scalar"
  require (ascii == "\\u{3bb}\x00\\u{e9}\\u{1f600}") "ASCII escaping preserves scalar identities"
  let colored := ({ color := true } : ReportStyle).finish "FAIL p\n- old\n+ new"
  require (colored.startsWith "\x1b[31mFAIL") "ANSI failure color"
  require (ReportStyle.limitLines 1 "one\ntwo" == "one\n... (1 more lines)") "value line budget"
  let evidence := Journal.renderWith { maxValueLines := 1 } #[
    { kind := .failure none, text := "first\nsecond" }]
  require (evidence == "FAIL: first\nsecond") "render budgets must retain failure evidence"
  let log : Trace := { trace with
    failureStep := some 3
    steps := #[
      { index := 1, rule := "create", touches := #[events[0]!] },
      { index := 2, rule := "unrelated", touches := #[
          { ref := ⟨9, 0⟩, operation := .reuse, clock := 5 }] },
      { index := 3, rule := "consume", failed := true, touches := #[events[1]!],
        origin := some { round := 2, worker := 1, group := some "writers" } }] }
  let rows := log.layoutRows { preference := .ascii }
  require (rows.size == 3 && rows[1]!.kind == .elision) "irrelevant steps collapse in trace"
  require (rows[1]!.text.startsWith "1 step elided") "trace elision counts"
  require (rows[2]!.origin == some "round 2, worker 1 (writers)") "worker origin retained"
  require (log.displayName { preference := .ascii } ⟨1, 0⟩ == "v1")
    "transferred identity keeps its original display name"
  require (GlyphTable.ascii.valueName none 0 1 != GlyphTable.ascii.valueName none 5 1)
    "pool labels remain distinct after first five pools"
  let custom : ReportStyle := {
    preference := .ascii
    phrases := { PhraseTable.english with elidedSteps := fun n _ => s!"hidden={n}" } }
  require ((log.layoutRows custom)[1]!.text == "hidden=1") "custom report phrase table"
  require ((log.renderWith { preference := .ascii }).toList.all (·.toNat < 128))
    "trace ASCII cleaning includes pool labels and worker origins"
  IO.println "ok: reporting/notes traces and source fallbacks"

  let settings : Settings := { seed := some 1, maxExamples := 10, database := none }
  let failure ← check "source assertion" sourceFailure settings
  require (failure.outcome == .failed && failure.failures.size == 1) failure.render
  let origin := failure.failures[0]!.origin
  require (origin.startsWith "assertion at Tests.Reporting:") "macro captures portable module"
  require ((← replay failure.failures[0]!.blob sourceFailure settings).origin == origin)
    "source assertion replay preserves origin"
  let other ← check "different source assertion" otherSourceFailure settings
  require (other.outcome == .failed && other.failures[0]!.origin != origin)
    "distinct source sites must not merge"
  let success ← check "source assertions pass" (do
    assert! true
    assertEq! (#[1, 2]) (#[1, 2])
    assertNe! (1 : Nat) 2
    assertProp! (1 < 2)
  ) settings
  require success.isSuccess success.render
  let noDatabase ← check "disabled empty database" otherSourceFailure {
    settings with database := some "" }
  require (noDatabase.outcome == .failed && noDatabase.reproduction == .unstored)
    "empty native database path must not claim stored reproduction"
  let ioFailure ← check "IO source assertion" ioSourceFailure settings
  require (ioFailure.outcome == .failed && ioFailure.failures.size == 1) ioFailure.render
  require (ioFailure.failures[0]!.origin.startsWith "assertion at Tests.Reporting:")
    "IO assertions retain source identity through forEach"
  require (ioFailure.failures[0]!.notes.any fun note => match note.kind with
    | .failure (some _) => true
    | _ => false) "IO assertion structural diff retained"
  require ((← replay ioFailure.failures[0]!.blob ioSourceFailure settings).origin ==
    ioFailure.failures[0]!.origin) "IO assertion replays at original source"
  let payload : Assertion.Payload := {
    message := "λ\x00failure", source, diff := some #[.removed "a\x00b", .added "c"] }
  let envelope := Assertion.IOEnvelope.encode payload
  require (Assertion.IOEnvelope.decode envelope == some payload)
    "IO assertion envelope preserves UTF-8 NUL and diff bytes"
  require ((Assertion.IOEnvelope.decode (IO.userError (toString envelope))).isNone)
    "ordinary user-error text cannot impersonate an assertion envelope"
  require ((Assertion.IOEnvelope.decode (.otherError 0x4845474c "malformed")).isNone)
    "malformed assertion envelope falls back to ordinary IO exception"
  require (match ioFailure.failures[0]!.evidence with
    | .reconstructed captured => captured.source.isSome && captured.diff.isSome
    | _ => false) "structured reconstructed evidence retains source and diff"
  let rich ← ioFailure.renderRichWith { preference := .ascii, color := true }
  require (rich.toList.all (·.toNat < 128)) "whole rich output obeys ASCII preference"
  require (!(rich.splitOn "\x1b[31m\x1b[").length > 1) "source output is not colored twice"
  IO.println "ok: reporting/source assertions shrinking and replay"
  reconstructionTests { settings with maxExamples := 100, reportMultipleFailures := true }
  provenanceTests settings

end Tests.Reporting
