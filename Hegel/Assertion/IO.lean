import Hegel.Report.Types
import Lean.Data.Json

namespace Hegel.Assertion

/-- Assertion metadata survives an ordinary `IO` callback without relying on message parsing. -/
structure Payload where
  message : String
  source : SourceLocation
  diff : Option Diff := none
  deriving Repr, BEq

namespace IOEnvelope

-- A dedicated error code and a versioned envelope distinguish assertions from user-error text.
private def code : UInt32 := 0x4845474c
private def tag : String := "hegel-lean/assertion/1"

private def sourceJson (source : SourceLocation) : Lean.Json := Lean.Json.mkObj [
  ("file", Lean.toJson source.file), ("module", Lean.toJson source.moduleName),
  ("line", Lean.toJson source.line), ("column", Lean.toJson source.column),
  ("endLine", Lean.toJson source.endLine), ("endColumn", Lean.toJson source.endColumn)]

private def diffJson (diff : Diff) : Lean.Json := Lean.toJson <| diff.map fun line =>
  match line with
  | .same text => (0, text)
  | .removed text => (1, text)
  | .added text => (2, text)

def encode (payload : Payload) : IO.Error :=
  .otherError code <| (Lean.Json.mkObj [
    ("tag", Lean.toJson tag), ("message", Lean.toJson payload.message),
    ("source", sourceJson payload.source),
    ("diff", payload.diff.map diffJson |>.getD .null)]).compress

private def decodeSource (json : Lean.Json) : Except String SourceLocation := do
  return {
    file := ← json.getObjValAs? String "file"
    moduleName := ← json.getObjValAs? String "module"
    line := ← json.getObjValAs? Nat "line"
    column := ← json.getObjValAs? Nat "column"
    endLine := ← json.getObjValAs? Nat "endLine"
    endColumn := ← json.getObjValAs? Nat "endColumn" }

private def decodeDiff (json : Lean.Json) : Except String (Option Diff) := do
  if json == .null then return none
  let lines ← Lean.fromJson? (α := Array (Nat × String)) json
  let lines ← lines.mapM fun (kind, text) => match kind with
    | 0 => pure (LineDiff.same text)
    | 1 => pure (LineDiff.removed text)
    | 2 => pure (LineDiff.added text)
    | _ => throw "Invalid assertion diff tag"
  return some lines

def decode (error : IO.Error) : Option Payload := do
  let .otherError errorCode contents := error | none
  if errorCode != code then return ← none
  let parsed : Except String Payload := do
    let json ← Lean.Json.parse contents
    unless (← json.getObjValAs? String "tag") == tag do throw "Not an assertion envelope"
    return {
      message := ← json.getObjValAs? String "message"
      source := ← decodeSource (← json.getObjVal? "source")
      diff := ← decodeDiff (← json.getObjVal? "diff") }
  parsed.toOption

end IOEnvelope
end Hegel.Assertion
