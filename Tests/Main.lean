import Hegel
import Lean.Data.Json
import Tests.MacIver
import Tests.Generators
import Tests.Reporting
import Tests.Stateful
import Tests.Safety
import Tests.Concurrency
import Tests.Replay
import Tests.LeanFeatures

open Hegel Hegel.Property

private def settings : Settings :=
  { seed := some 42, maxExamples := 100, database := none }

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def passes (name : String) (p : Property Unit) : IO Unit := do
  let report ← check name p settings
  require report.isSuccess report.render
  IO.println s!"ok: {name} ({report.evaluations} evaluations)"

private def fails (name : String) (p : Property Unit) : IO Report := do
  let report ← check name p settings
  require (report.outcome == .failed && !report.failures.isEmpty) report.render
  for f in report.failures do
    let again ← replay f.blob p settings
    require (again.status == .failed && again.origin == f.origin) s!"Bad replay: {reprStr again}"
    require (again.annotations == f.annotations) "Replay changed counterexample values"
  IO.println s!"ok: {name} shrank and replayed"
  return report

private def rejects (name : String) (p : Property Unit) : IO Unit := do
  let report ← check name p settings
  require (report.outcome == .error) s!"Expected error, got {report.render}"
  IO.println s!"ok: {name} rejected"

private def small : Property Unit := do
  let n ← forAll (Gen.int 0 100) "n"
  assertThat (n < 5) "small"

inductive Tree where
  | leaf (n : Int)
  | branch (left right : Tree)
  deriving Repr

def Tree.leaves : Tree → Nat
  | .leaf _ => 1
  | .branch a b => a.leaves + b.leaves

def Tree.branches : Tree → Nat
  | .leaf _ => 0
  | .branch a b => a.branches + b.branches + 1

def main : IO Unit := do
  let lock ← IO.FS.readFile "engine-lock.json"
  let expected ← IO.ofExcept do
    let json ← Lean.Json.parse lock
    json.getObjValAs? String "version"
  require ((← engineVersion) == expected) "Engine version does not match engine-lock.json"
  for n in #[-(2^200), -(2^64), -32769, -129, -128, -1, 0, 1, 127, 128, 255, 256,
      32768, 2^64, 2^200] do
    require (Gen.decodeInt (Gen.encodeInt n) == n) s!"Signed encoding failed for {n}"
  passes "booleans and endpoints" do
    assertEq (← forAll (Gen.bool 0)) false "p=0"
    assertEq (← forAll (Gen.bool 1)) true "p=1"
    let n ← forAll (Gen.int (-100) 100)
    assertProp (-100 ≤ n ∧ n ≤ 100) "integer bounds"
  passes "arbitrary precision" do
    for (lo, hi) in #[(-(2^200), -(2^199)), (2^100, 2^200), (-(2^200), 2^200),
        (2^200, 2^200), (-(2^200), -(2^200))] do
      let n ← forAll (Gen.int lo hi)
      assertProp (lo ≤ n ∧ n ≤ hi) "big integer bounds"
  passes "dependent draws and assumptions" do
    let lo ← forAll (Gen.nat 0 50)
    let hi ← forAll (Gen.nat lo (lo + 100))
    assume (hi > lo)
    assertProp (lo < hi) "dependent bound"
  passes "collections and nested shrinking spans" do
    let xs ← forAll (Gen.list (Gen.int (-20) 20) 2 12)
    assertEq xs.reverse.reverse xs "reverse twice"
    assertProp (2 ≤ xs.length ∧ xs.length ≤ 12) "list bounds"
    let nested ← forAll (Gen.array (Gen.array (Gen.nat 0 10) 0 5) 0 4)
    assertThat (nested.all (fun xs => xs.size ≤ 5)) "nested lengths"
    let vec ← forAll (Gen.vector (Gen.bool) 7)
    assertEq vec.size 7 "vector size"
    let i ← forAll (Gen.fin 17 (by decide))
    assertProp (i.val < 17) "fin bound"
  passes "Unicode including NUL" do
    let s ← forAll (Gen.text { minSize := 2, maxSize := 8 })
    assertProp (2 ≤ s.length ∧ s.length ≤ 8) "Unicode character length"
    let nul ← forAll (Gen.text { minSize := 3, maxSize := 3, maxCodepoint := 0 })
    assertEq nul.toUTF8.size 3 "NUL byte length"
    assertThat (nul.toList.all (· == '\x00')) "NUL preserved"
    let b ← draw (Gen.bytes 3 10)
    assertProp (3 ≤ b.size ∧ b.size ≤ 10) "byte length"
  passes "text formats" do
    let s ← forAll (Gen.regex "[a-z]{2}[0-9]{3}")
    assertEq s.length 5 "regex length"
    let e ← forAll Gen.email
    assertThat (e.contains '@') "email shape"
    let u ← forAll Gen.url
    assertThat (u.startsWith "http") "url scheme"
    let d ← forAll (Gen.domain 50)
    assertThat (d.length ≤ 50) "domain bound"
  passes "floats and filters" do
    let f ← forAll (Gen.float {
      min := -100, max := 100, allowNaN := false, allowInfinity := false })
    assertThat (f ≥ -100 && f ≤ 100) "float bounds"
    let n ← forAll (Gen.filter (fun n => n % 2 == 0) (Gen.nat 0 100))
    assertEq (n % 2) 0 "even filter"
    target n.toFloat
  passes "unique and optional" do
    let xs ← forAll (Gen.uniqueArray (Gen.nat 0 100) 2 12)
    assertEq xs.toList.eraseDups.length xs.size "unique values"
    let opt ← forAll (Gen.option (Gen.element #[10, 20, 30]))
    assertThat (opt.all (#[10, 20, 30].contains ·)) "optional choice"
  passes "recursive trees" do
    let tree ← forAll (Gen.recursive 6 (Tree.leaf <$> Gen.int 0 10)
      (fun child => Tree.branch <$> child <*> child))
    assertEq tree.leaves (tree.branches + 1) "tree identity"
  passes "function-valued generators" do
    let f ← draw ((fun n x => x + n) <$> Gen.nat 0 50)
    assertEq (f 10 - f 0) 10 "generated function"
  let report ← fails "integer minimum" small
  require (report.failures[0]!.annotations == #["n = 5"]) report.render
  let listReport ← fails "list minimum" do
    let xs ← forAll (Gen.list (Gen.nat 0 100) 0 20) "xs"
    assertThat (xs.length < 3) "short list"
  require (listReport.failures[0]!.annotations == #["xs = [0, 0, 0]"]) listReport.render
  let multiple ← fails "distinct failure origins" do
    let n ← forAll (Gen.int (-100) 100)
    if n < 0 then failure "negative" else if n > 0 then failure "positive"
  require (multiple.failures.size == 2) multiple.render
  rejects "inverted bounds" (draw (Gen.int 10 0) *> pure ())
  rejects "empty choice" (draw (Gen.element (#[] : Array Nat)) *> pure ())
  rejects "oversized collection" (draw (Gen.list Gen.bool 0 (2^64)) *> pure ())
  rejects "health check" (assume false)
  rejects "NUL in regex" (draw (Gen.regex "a\x00b") *> pure ())
  let ioReport ← fails "IO exception" do
    io (throw (IO.userError "test exception") : IO Unit) "test IO"
  require (ioReport.failures[0]!.message.contains "test exception") ioReport.render
  let dir := ".lake/test-database"
  if ← System.FilePath.pathExists dir then IO.FS.removeDirAll dir
  let dbSettings := { settings with database := some dir }
  let stored ← check "persistent-small" small dbSettings
  require (stored.outcome == .failed) stored.render
  let reused ← check "persistent-small" small { dbSettings with phases := #[.reuse] }
  require (reused.outcome == .failed) reused.render
  IO.println "ok: persisted counterexample replayed in reuse-only phase"
  let malformed ← (replay "not a valid blob" small).toBaseIO
  require (match malformed with | .error _ => true | .ok _ => false) "Invalid replay blob accepted"
  let session ← (Internal.openSession 10 42 true "" "lifecycle" false 30 0).toIO
    (IO.userError ∘ toString)
  (Internal.startRun session).toIO (IO.userError ∘ toString)
  let worker ← (Internal.next session).asTask
  require (match worker.get with | .error e => e.code == -9 | _ => false)
    "Cross-thread session access was not rejected"
  (Internal.close session).toIO (IO.userError ∘ toString)
  (Internal.close session).toIO (IO.userError ∘ toString)
  let closed ← (Internal.next session).toBaseIO
  require (match closed with | .error e => e.code == -4 | _ => false)
    "Closed session access was not rejected"
  IO.println "ok: thread confinement, idempotent close, and use-after-close rejection"
  IO.println "All Hegel integration tests passed."
  let receipts ← Tests.MacIver.run
  Tests.MacIver.writeReceipts ".lake/maciver-results.json" receipts
  Tests.Generators.run
  Tests.Reporting.run
  Tests.Stateful.run
  Tests.Safety.run
  Tests.Concurrency.run
  Tests.Replay.run
  Tests.LeanFeatures.run
