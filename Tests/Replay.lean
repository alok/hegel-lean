import Hegel.Replay

open Hegel Hegel.Property

namespace Tests.Replay

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def settings : Settings := { database := none, seed := some 42, maxExamples := 100 }

private def property : Property Unit := do
  let value ← forAll (Gen.nat 0 20)
  assertThat (value < 5) "replay/λ:small" "value is too large"

private def reasonIs (report : Report) (reason : ReplayReason) : Bool :=
  report.outcome == .error && report.failures.any fun failure ↦
    match failure.evidence with | .diverged actual => actual == reason | _ => false

def run : IO Unit := do
  let encoded := encodeReplayToken ⟨"0.43.1", "λ:origin\x00", "blob"⟩
  require (encoded == "hegel-replay:0.43.1:cebb3a6f726967696e00:blob") "Replay encoding changed"
  require ((decodeReplayToken encoded).toOption == some ⟨"0.43.1", "λ:origin\x00", "blob"⟩)
    "UTF-8/NUL replay token roundtrip failed"
  for (text, expected) in #[
      ("other:1:61:x", ReplayError.unsupportedFormat "other"),
      ("hegel-replay:1:61", .malformedEnvelope),
      ("hegel-replay::61:x", .emptyField),
      ("hegel-replay:1:6:x", .invalidOriginHex),
      ("hegel-replay:1:zz:x", .invalidOriginHex),
      ("hegel-replay:1:ff:x", .originNotUtf8)] do
    require (match decodeReplayToken text with | .error error => error == expected | .ok _ => false)
      s!"Accepted malformed replay token {text}"
  IO.println "ok: portable replay token encoding and malformed-envelope classification"
  let sourceReport ← check "replay-token-source" property settings
  let some found  := sourceReport.failures[0]? | throw (IO.userError sourceReport.render)
  let some token ← found.replayToken | throw (IO.userError "Missing counterexample token")
  let replayed ← replayToken token property settings
  require (replayed.outcome == .failed) replayed.render
  require (replayed.stats.replay.any (·.reproduced == 1)) "Missing reproduced replay count"
  require (replayed.failures.any (·.annotations == found.annotations)) "Token changed observations"
  let unchanged ← IO.mkRef true
  let incompatible ← replayToken { token with version := "different-engine" } (do
    unchanged.set false) settings
  require ((← unchanged.get) && reasonIs incompatible (.incompatibleVersions "different-engine" token.version))
    incompatible.render
  let passed ← replayToken token (pure ()) settings
  require (reasonIs passed .unexpectedSuccess) passed.render
  let discarded ← replayToken token discard settings
  require (reasonIs discarded .unexpectedDiscard) discarded.render
  let overrun ← replayToken token (throw .overrun) settings
  require (reasonIs overrun .exhaustedChoices) overrun.render
  let changed ← replayToken token (failure "changed") settings
  require (reasonIs changed (.changedOrigin "changed")) changed.render
  IO.println "ok: replay tokens enforce engine version, failure identity, status, and observations"

end Tests.Replay
