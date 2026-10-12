import Hegel
import Lean.Data.Json

/-! Optional engine-upgrade diagnostic. Unlike the fixed acceptance seeds, this sweep currently
exposes known shrinker failures. Every nonminimal witness, discovery miss, or execution error
makes the process fail; none is an expected-success test. -/

open Hegel Hegel.Property Lean

private def runSeed (seed : Nat) : IO (String × Json) := do
  let observed ← IO.mkRef (none : Option (Int × Int))
  let calls ← IO.mkRef 0
  let property : Property Unit := do
    let count ← calls.modifyGet fun n ↦ (n + 1, n + 1)
    if count > 150000 then throw (.error "adjacent-uint64: execution budget exceeded")
    let value ← draw (Gen.filter (fun (m, n) ↦ m != n)
      (Gen.pair (Gen.int 0 (2^64 - 1)) (Gen.int 0 (2^64 - 1))) 10)
    observed.set (some value)
    annotate s!"input = {reprStr value}"
    if (value.1 - value.2).natAbs ≤ 1 then failure "adjacent-uint64"
  let settings : Settings := { seed := some seed.toUInt64, maxExamples := 1000, database := none }
  let report ← check "adjacent-uint64" property settings
  let mut witness := "unavailable"
  let mut result := if report.isSuccess then "missed" else "error"
  let mut replays := 0
  if report.outcome == .failed && report.failures.size == 1 then
    let found := report.failures[0]!
    if !found.blob.isEmpty && found.origin == "adjacent-uint64" then
      for _ in [:2] do
        let again ← replay found.blob property settings
        if again.status != .failed || again.origin != found.origin ||
            !again.cleanupDiagnostics.isEmpty || again.annotations != found.annotations then
          break
        replays := replays + 1
      if replays == 2 then
        if let some pair ← observed.get then
          witness := reprStr pair
          if pair == (0, 1) || pair == (1, 0) then result := "minimal"
          else if 0 ≤ pair.1 && pair.1 < 2^64 && 0 ≤ pair.2 && pair.2 < 2^64 &&
              pair.1 != pair.2 && (pair.1 - pair.2).natAbs ≤ 1 then
            result := "nonminimal"
  return (result, Json.mkObj [
    ("seed", toJson seed), ("result", toJson result), ("witness", toJson witness),
    ("evaluations", toJson report.evaluations), ("replays", toJson replays),
    ("outcome", toJson (reprStr report.outcome)), ("message", toJson report.message)])

/-- Sweep seeds from zero, writing JSONL and returning nonzero unless every seed finds the
minimal witness and reproduces it twice. Optional argument: seed count (1–10000; default 200). -/
def main (args : List String) : IO UInt32 := do
  let count ← match args with
    | [] => pure 200
    | [arg] => match arg.toNat? with
      | some count => pure count
      | none => throw (IO.userError "Expected a seed count")
    | _ => throw (IO.userError "Usage: hegel_adjacent_sweep [seed-count]")
  unless 0 < count && count ≤ 10000 do
    throw (IO.userError "Seed count must be between 1 and 10000")
  let mut nonminimal := 0
  let mut missed := 0
  let mut errors := 0
  for seed in [:count] do
    let (result, row) ← try runSeed seed catch e =>
      pure ("error", Json.mkObj [
        ("seed", toJson seed), ("result", toJson "error"), ("message", toJson (toString e))])
    if result == "nonminimal" then nonminimal := nonminimal + 1
    if result == "missed" then missed := missed + 1
    if result == "error" then errors := errors + 1
    IO.println row.compress
  IO.println (Json.mkObj [
    ("engine", toJson (← engineVersion)), ("seeds", toJson count),
    ("minimal", toJson (count - nonminimal - missed - errors)),
    ("nonminimal", toJson nonminimal), ("missed", toJson missed),
    ("errors", toJson errors)]).compress
  return if nonminimal == 0 && missed == 0 && errors == 0 then 0 else 1
