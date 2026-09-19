import Hegel.Runner

namespace Hegel

/-- Portable engine metadata and the expected failure identity for a stored choice stream. -/
structure ReplayToken where
  version : String
  origin : String
  blob : String
  deriving Repr, BEq, Inhabited

inductive ReplayError where
  | malformedEnvelope
  | unsupportedFormat (format : String)
  | emptyField
  | invalidOriginHex
  | originNotUtf8
  deriving Repr, BEq, Inhabited

def replayTokenVersion (token : ReplayToken) : String := token.version
def replayTokenOrigin (token : ReplayToken) : String := token.origin

private def hexDigit (n : Nat) : Char :=
  Char.ofNat (if n < 10 then 48 + n else 87 + n)

private def encodeOrigin (origin : String) : String :=
  String.ofList <| origin.toUTF8.data.toList.flatMap fun byte ↦
    [hexDigit (byte.toNat / 16), hexDigit (byte.toNat % 16)]

/-- The textual envelope is compatible with the pinned reference client. -/
def encodeReplayToken (token : ReplayToken) : String :=
  String.intercalate ":" ["hegel-replay", token.version, encodeOrigin token.origin, token.blob]

private def decodeDigit (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - 48)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 87)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 55)
  else none

private def decodeOrigin (text : String) : Except ReplayError String := do
  let chars := text.toList.toArray
  if chars.size % 2 != 0 then throw .invalidOriginHex
  let mut bytes := ByteArray.empty
  for i in [:chars.size / 2] do
    let some hi := decodeDigit chars[i * 2]! | throw .invalidOriginHex
    let some lo := decodeDigit chars[i * 2 + 1]! | throw .invalidOriginHex
    bytes := bytes.push (hi * 16 + lo).toUInt8
  match String.fromUTF8? bytes with
  | some value => return value
  | none => throw .originNotUtf8

def decodeReplayToken (text : String) : Except ReplayError ReplayToken := do
  match text.splitOn ":" with
  | ["hegel-replay", version, origin, blob] =>
    if version.isEmpty || origin.isEmpty || blob.isEmpty then throw .emptyField
    return ⟨version, ← decodeOrigin origin, blob⟩
  | format :: _ =>
    if format != "hegel-replay" then throw (.unsupportedFormat format)
    throw .malformedEnvelope
  | [] => throw .malformedEnvelope

def Failure.replayToken (failure : Failure) : IO (Option ReplayToken) := do
  if failure.blob.isEmpty then return none
  return some ⟨← engineVersion, failure.origin, failure.blob⟩

/-- Replay exactly once and verify both engine compatibility and the expected failure origin. -/
def replayToken (token : ReplayToken) (property : Property Unit)
    (settings : Settings := {}) : IO Report := do
  let name := "replay " ++ token.origin
  let version ← engineVersion
  let divergent := fun reason => ({
    name, outcome := .error, message := reason.render
    failures := #[{
      origin := token.origin, blob := token.blob, message := reason.render
      annotations := #[], evidence := .diverged reason }]
    stats := { replay := some {} } } : Report)
  if token.version != version then
    return divergent (.incompatibleVersions token.version version)
  if let .error error := settings.validate then
    return divergent (.reconstructionAborted (toString error))
  let result ← (replay token.blob property settings).toBaseIO
  match result with
  | .error error => return divergent (.invalidReplayBlob (toString error))
  | .ok case =>
    let reason := case.replayReason token.origin
    let evidence := match reason with
      | some reason => FailureEvidenceStatus.diverged reason
      | none => .reconstructed case.toEvidence
    let reproduced := reason.isNone
    return {
      name, outcome := if reproduced && case.cleanupDiagnostics.isEmpty then .failed else .error
      evaluations := 1
      failures := #[{
        origin := token.origin, blob := token.blob, message := case.message
        annotations := case.annotations, notes := case.notes
        trace := Trace.build case.notes case.events
        cleanupDiagnostics := case.cleanupDiagnostics, evidence }]
      message := if !case.cleanupDiagnostics.isEmpty then "Replay resource cleanup failed"
        else reason.map ReplayReason.render |>.getD ""
      cleanupDiagnostics := case.cleanupDiagnostics
      stats := { replay := some {
        attempted := 1
        valid := if case.status == .passed || case.status == .failed then 1 else 0
        invalid := if case.status == .discarded then 1 else 0
        exhausted := if case.status == .overrun then 1 else 0
        reproduced := if reproduced then 1 else 0 } } }

end Hegel
