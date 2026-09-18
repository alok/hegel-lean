import Hegel
import Lean.Data.Json

/-!
Regression cases derived from David R. MacIver's writing. Source links, adaptations, and
claim boundaries are in docs/maciver-tests.md. Deliberately false properties must fail,
shrink to the independently specified witness, and reproduce twice from their blobs.
-/
namespace Tests.MacIver
open Hegel Hegel.Property

structure Receipt where
  name : String
  seed : Nat
  kind : String := "regression"
  result : String := "passed"
  evaluations : Nat
  milliseconds : Nat
  firstFailure : String
  finalWitness : String
  replays : Nat
  deriving Lean.ToJson

private def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def settings (seed : UInt64) : Settings :=
  { seed := some seed, maxExamples := 1000, database := none }

/-- Observe values without allowing the observer's state to influence the property. -/
private def minimum [Repr α] (name : String) (seed : UInt64) (produce : Property α)
    (interesting expected : α → Bool) (valid : α → Bool := fun _ ↦ true)
    (discovery : Bool := false) : IO Receipt := do
  let observed ← IO.mkRef (none : Option α)
  let first ← IO.mkRef (none : Option α)
  let calls ← IO.mkRef 0
  let property : Property Unit := do
    let count ← io (calls.modifyGet fun n ↦ (n + 1, n + 1))
    if count > 150000 then throw (.error s!"{name}: exceeded the test's execution budget")
    let value ← produce
    io (observed.set (some value))
    annotate s!"input = {reprStr value}"
    assertThat (valid value) s!"{name}/generator-invariant"
    if interesting value then
      io (first.modify fun old ↦ old.or (some value))
      failure name
  let start ← IO.monoMsNow
  let report ← check name property (settings seed)
  if discovery && report.isSuccess then
    ensure ((← first.get).isNone) "A passing report lost an observed failure"
    return {
      name, seed := seed.toNat, kind := "discovery", result := "missed"
      evaluations := report.evaluations, milliseconds := (← IO.monoMsNow) - start
      firstFailure := "not found", finalWitness := "not found", replays := 0
    }
  ensure (report.outcome == .failed && report.failures.size == 1) report.render
  let failure := report.failures[0]!
  ensure (failure.origin == name && !failure.blob.isEmpty) report.render
  let mut last := ""
  for _ in [:2] do
    observed.set none
    let repeated ← replay failure.blob property (settings seed)
    ensure (repeated.status == .failed && repeated.origin == name) (reprStr repeated)
    ensure (repeated.annotations == failure.annotations) "Replay changed the final annotations"
    let some witness ← observed.get | throw (IO.userError "Replay did not produce a witness")
    ensure (valid witness && interesting witness && expected witness)
      s!"{name}: unexpected witness {reprStr witness}\n{report.render}"
    last := reprStr witness
  let some initial ← first.get | throw (IO.userError "No initial failure was observed")
  return {
    name, seed := seed.toNat, evaluations := report.evaluations
    kind := if discovery then "discovery" else "regression"
    result := if discovery then "found" else "passed"
    milliseconds := (← IO.monoMsNow) - start, firstFailure := reprStr initial
    finalWitness := last, replays := 2
  }

-- https://drmaciver.com/2015/04/honey-i-shrunk-the-clones/
private def duplicateTriples (seed : UInt64) : IO Receipt :=
  minimum "duplicate-triples" seed (draw (Gen.list (Gen.int (-100) 100) 0 20))
    (fun xs ↦ xs.any fun x ↦ (xs.filter (· == x)).length ≥ 3)
    (· == [0, 0, 0])

-- Same post's explicit stress predicate, with finite generation bounds.
private def seventyLarge (seed : UInt64) : IO Receipt :=
  minimum "seventy-large-elements" seed (draw do
    let size ← Gen.nat 0 100
    Gen.list (Gen.nat 0 1000) size size)
    (fun xs ↦ (xs.filter (· ≥ 10)).length ≥ 70)
    (· == List.replicate 70 10)

private def seventyDiscovery (seed : UInt64) : IO Receipt :=
  minimum "seventy-default-discovery" seed (draw (Gen.list (Gen.nat 0 1000) 0 100))
    (fun xs ↦ (xs.filter (· ≥ 10)).length ≥ 70)
    (· == List.replicate 70 10) (discovery := true)

-- https://drmaciver.com/2018/01/a-pathological-example-for-test-case-reduction/
private def nearby64 (seed : UInt64) : IO Receipt :=
  minimum "nearby-uint64" seed
    (draw (Gen.pair (Gen.int 0 (2^64 - 1)) (Gen.int 0 (2^64 - 1))))
    (fun (m, n) ↦ (m - n).natAbs ≤ 1)
    (· == (0, 0))

-- Exclude equal pairs to exercise the adjacent-value case discussed in the post.
private def adjacent64 (seed : UInt64) : IO Receipt :=
  minimum "adjacent-uint64" seed
    (draw (Gen.filter (fun (m, n) ↦ m != n)
      (Gen.pair (Gen.int 0 (2^64 - 1)) (Gen.int 0 (2^64 - 1))) 10))
    (fun (m, n) ↦ (m - n).natAbs ≤ 1)
    (fun pair ↦ pair == (0, 1) || pair == (1, 0))
    (fun (m, n) ↦ m != n)

-- https://drmaciver.com/2015/02/monadic-data-generation-strategies-and-why-you-should-are/
private def nonInjectiveMap (seed : UInt64) : IO Receipt :=
  minimum "non-injective-map" seed (draw ((· / 100) <$> Gen.nat 0 1000000))
    (· > 0) (· == 1)

structure ZonedMinute where
  offset : Int
  minute : Nat
  deriving Repr, BEq

private def sharedTimezone (seed : UInt64) : IO Receipt :=
  minimum "shared-timezone" seed (draw do
    let offset ← Gen.int (-720) 840
    let entries ← Gen.list (ZonedMinute.mk offset <$> Gen.nat 0 1439) 0 10
    return (offset, entries))
    (fun (_, xs) ↦ xs.length ≥ 2)
    (· == (0, [⟨0, 0⟩, ⟨0, 0⟩]))
    (fun (offset, xs) ↦ xs.all (·.offset == offset))

-- https://drmaciver.com/2015/11/conjecture-parametrization-and-data-distribution/
private def unusedOption (seed : UInt64) : IO Receipt :=
  minimum "irrelevant-option" seed
    (draw (Gen.pair (Gen.option (Gen.list (Gen.int (-100) 100))) (Gen.nat 0 100)))
    (fun (_, n) ↦ n ≥ 10) (· == (none, 10))

private def firstBranch (seed : UInt64) : IO Receipt :=
  minimum "first-branch" seed
    (draw (Gen.oneOf #[pure "first", pure "second", pure "third"]))
    (fun _ ↦ true) (· == "first")

private def filteredDraw (seed : UInt64) : IO Receipt :=
  minimum "filtered-draw" seed (draw (Gen.filter (· ≥ 10) (Gen.nat 0 100)))
    (fun _ ↦ true) (· == 10) (· ≥ 10)

-- https://drmaciver.com/2016/03/the-easy-way-to-get-started-with-property-based-testing/
private def astralText (seed : UInt64) : IO Receipt :=
  minimum "astral-text" seed (draw (Gen.text { maxSize := 8 }))
    (fun s ↦ s.toList.any (fun c ↦ c.toNat ≥ 0x10000))
    (fun s ↦ s.length == 1 && s.toList.any (fun c ↦ c.toNat ≥ 0x10000))
    (fun s ↦ String.fromUTF8? s.toUTF8 == some s)

-- https://drmaciver.com/2015/09/a-new-approach-to-property-based-testing/
private def interleavedEffects (seed : UInt64) : IO Receipt :=
  minimum "interleaved-effects" seed (do
    let state ← io (IO.mkRef (0 : Nat))
    let lo ← draw (Gen.nat 0 100)
    io (state.set lo)
    let saved ← io state.get
    let hi ← draw (Gen.nat saved (saved + 100))
    return (lo, saved, hi))
    (fun (lo, _, hi) ↦ hi ≥ lo + 5)
    (· == (0, 0, 5))
    (fun (lo, saved, hi) ↦ lo == saved && lo ≤ hi)

-- https://hypothesis.works/articles/multi-bug-discovery/ (also authored by MacIver)
private def multipleBugs (seed : UInt64) (discovery : Bool := false) : IO Receipt := do
  let observed ← IO.mkRef ([] : List Float)
  let values := if discovery then Gen.float else Gen.oneOf #[Gen.float, pure (0 / 0 : Float)]
  let property : Property Unit := do
    let xs ← forAll (Gen.list values 0 12) "floats"
    io (observed.set xs)
    match xs with
    | [] => failure "mean/empty" "minimum of an empty list"
    | x :: rest =>
      let low := rest.foldl (fun a b ↦ if b < a then b else a) x
      let high := rest.foldl (fun a b ↦ if b > a then b else a) x
      let mean := xs.foldl (· + ·) 0 / xs.length.toFloat
      assertThat (low ≤ mean && mean ≤ high) "mean/outside-bounds"
  let start ← IO.monoMsNow
  let report ← check "multiple-bugs" property (settings seed)
  ensure (report.outcome == .failed && !report.failures.isEmpty) report.render
  if !discovery then ensure (report.failures.size == 2) report.render
  ensure ((report.failures.map (·.origin)).contains "mean/empty") report.render
  let foundBoth := (report.failures.map (·.origin)).contains "mean/outside-bounds"
  for f in report.failures do
    let mut priorBits : Option (List UInt64) := none
    for _ in [:2] do
      let repeated ← replay f.blob property (settings seed)
      ensure (repeated.status == .failed && repeated.origin == f.origin) (reprStr repeated)
      ensure (repeated.annotations == f.annotations) "Floating-point replay changed"
      let xs ← observed.get
      let bits := xs.map Float.toBits
      if let some previous := priorBits then
        ensure (bits == previous) "Replay changed floating-point bits (including NaN payloads)"
      priorBits := some bits
      if f.origin == "mean/empty" then ensure xs.isEmpty report.render
      else
        ensure (f.origin == "mean/outside-bounds") report.render
        ensure (xs.length == 1 && xs.any Float.isNaN) report.render
  return {
    name := if discovery then "multiple-bugs-default-discovery" else "multiple-bugs"
    seed := seed.toNat, evaluations := report.evaluations
    kind := if discovery then "discovery" else "regression"
    result := if discovery then (if foundBoth then "found" else "missed") else "passed"
    milliseconds := (← IO.monoMsNow) - start, firstFailure := "not recorded"
    finalWitness := if foundBoth then "[] and [NaN]" else "[] only; NaN not found"
    replays := 2 * report.failures.size
  }

private def unicodeRoundtrip (seed : UInt64) : IO Receipt := do
  let start ← IO.monoMsNow
  let report ← check "unicode-roundtrip" (do
    let s ← forAll (Gen.text { maxSize := 64 })
    assertEq (String.fromUTF8? s.toUTF8) (some s) "UTF-8 roundtrip") (settings seed)
  ensure (report.isSuccess && report.evaluations > 0) report.render
  return {
    name := "unicode-roundtrip", seed := seed.toNat, evaluations := report.evaluations
    milliseconds := (← IO.monoMsNow) - start, firstFailure := "none"
    finalWitness := "passing control", replays := 0
  }

private def cases : Array (UInt64 → IO Receipt) := #[duplicateTriples, seventyLarge, nearby64,
  adjacent64, nonInjectiveMap, sharedTimezone, unusedOption, firstBranch, filteredDraw,
  astralText, interleavedEffects, (multipleBugs ·), unicodeRoundtrip,
  seventyDiscovery, (multipleBugs · true)]

def run (seeds : Array UInt64 := #[0, 1, 42]) : IO (Array Receipt) := do
  let mut receipts := #[]
  let mut errors : Array String := #[]
  for seed in seeds do
    for scenario in cases do
      try
        let receipt ← scenario seed
        receipts := receipts.push receipt
        let status := if receipt.result == "missed" then "MISS" else "ok"
        IO.println s!"{status}: MacIver/{receipt.name} seed={seed} \
          evaluations={receipt.evaluations} elapsed={receipt.milliseconds}ms \
          replays={receipt.replays} witness={receipt.finalWitness}"
      catch e =>
        errors := errors.push s!"seed={seed}: {e}"
        IO.eprintln s!"FAIL: MacIver seed={seed}: {e}"
  unless errors.isEmpty do
    let details := String.intercalate "\n" errors.toList
    throw (IO.userError s!"{errors.size} MacIver regressions failed:\n{details}")
  let regressions := receipts.filter (·.kind == "regression")
  let probes := receipts.filter (·.kind == "discovery")
  let misses := probes.filter (·.result == "missed")
  IO.println s!"All {regressions.size} MacIver regressions passed; \
    {misses.size}/{probes.size} discovery probes missed an expected bug."
  return receipts

/-- Machine-readable evidence; discovery misses are retained separately from regression results. -/
def writeReceipts (path : System.FilePath) (receipts : Array Receipt) : IO Unit := do
  let payload := Lean.Json.mkObj [
    ("engineVersion", Lean.toJson (← Hegel.engineVersion)),
    ("leanToolchain", Lean.toJson (← IO.FS.readFile "lean-toolchain").trimAscii.toString),
    ("regressions", Lean.toJson (receipts.filter (·.kind == "regression")).size),
    ("discoveryProbes", Lean.toJson (receipts.filter (·.kind == "discovery")).size),
    ("discoveryMisses", Lean.toJson (receipts.filter (·.result == "missed")).size),
    ("results", Lean.toJson receipts)]
  IO.FS.writeFile path (payload.pretty ++ "\n")

end Tests.MacIver
