import Hegel

open Hegel Hegel.Property

namespace Tests.Safety

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def settings : Settings := { database := none, seed := some 42, maxExamples := 10 }

def run : IO Unit := do
  let impossible : Property Unit := do
    let _ ← draw (Gen.nat 0 100)
    assume false
  let exhausted ← check "no-valid-examples" impossible {
    settings with suppressHealthCheck := #[.filterTooMuch] }
  require (!exhausted.isSuccess) "Rejection exhaustion was reported as a pass"
  for config in #[{ settings with maxExamples := 0 }, { settings with phases := #[] },
      { settings with phases := #[.reuse] }] do
    let report ← check "empty-campaign" (failure "never-run") config
    require (!report.isSuccess) "A campaign with no valid executions passed"
  IO.println "ok: empty and rejection-exhausted campaigns never pass"
  let report ← check "caught-span-discard" (do
    for _ in [:1200] do
      try draw (Gen.withSpan "discarded" (Gen.discard : Gen Unit))
      catch | .discard => pure () | error => throw error
    let _ ← draw (Gen.nat 0 100)
    pure ()) { settings with maxExamples := 1 }
  require report.isSuccess report.render
  IO.println "ok: caught generator aborts release all native spans"
  let large ← check "large-fixed-collection" (do
    let values ← draw (Gen.vector (pure (0 : Nat)) 1500)
    assertEq values.size 1500 "large collection length") {
      settings with
      maxExamples := 1, unboundedChoices := true
      suppressHealthCheck := #[.largeInitialTestCase, .testCasesTooLarge] }
  require large.isSuccess large.render
  IO.println "ok: large flat collections do not consume recursive span depth"
  let order ← IO.mkRef (#[] : Array Nat)
  let cleanup ← check "cleanup-failure-preserves-original" (do
    registerFinalizer do
      order.modify (·.push 1)
      throw (IO.userError "first resource")
    registerFinalizer do
      order.modify (·.push 2)
      throw (IO.userError "second resource")
    failure "original-assertion" "original failure") settings
  require (cleanup.outcome == .error && cleanup.evaluations == 1) cleanup.render
  require (cleanup.cleanupDiagnostics.size == 2) "Cleanup diagnostics were dropped"
  require (cleanup.failures.any (·.origin == "original-assertion")) "Original failure was overwritten"
  require ((← order.get) == #[2, 1]) "Finalizers did not all run in reverse order"
  IO.println "ok: cleanup errors retain evidence and stop unsafe reruns"
  let fixed ← check "fixed-unique-collection" (do
    let values ← draw (Gen.uniqueArray (Gen.nat 0 10) 4 4)
    assertThat (values.size == 4 && values.toList.eraseDups.length == 4) "fixed unique size") settings
  require fixed.isSuccess fixed.render
  IO.println "ok: fixed-size unique collections retain their cardinality"
  let values ← Hegel.samples 8 (pure (17 : Nat)) settings
  require (values == #[17]) "Finite-space exhaustion must stop a sampling campaign"
  let draws ← IO.mkRef 0
  let rejected : Gen Nat := Gen.ofRun fun _ => do
    draws.modify (· + 1)
    throw .discard
  let single ← (Hegel.sample rejected settings).toBaseIO
  require (single matches .error _) "A rejected single sample unexpectedly succeeded"
  require ((← draws.get) == 1) "Single sampling retried a discarded case"
  require ((← Hegel.samples 0 (pure (0 : Nat)) settings).isEmpty) "Zero sampling requested a case"
  IO.println "ok: sampling preserves single-case rejection and campaign exhaustion semantics"

end Tests.Safety
