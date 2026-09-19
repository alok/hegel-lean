import Hegel
import Hegel.Gen.Recursive

namespace Tests.Generators
open Hegel Hegel.Property

private def settings : Settings := { seed := some 42, maxExamples := 100, database := none }

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def passes (name : String) (p : Property Unit) : IO Unit := do
  let report ← check name p settings
  require report.isSuccess report.render
  IO.println s!"ok: {name} ({report.evaluations} evaluations)"

private def rejects (name : String) (p : Property Unit) : IO Unit := do
  let report ← check name p settings
  require (report.outcome == .failed && !report.failures.isEmpty)
    s!"Expected a configuration counterexample: {report.render}"
  for failure in report.failures do
    let again ← replay failure.blob p settings
    require (again.status == .failed && again.origin == failure.origin)
      "Validation replay changed the failure"
  IO.println s!"ok: {name} rejected and replayed"

private def shrinks [Repr α] (name : String) (gen : Gen α) (expected : α → Bool) : IO Unit := do
  let observed ← IO.mkRef none
  let property : Property Unit := do
    let value ← forAll gen "value"
    io (observed.set (some value))
    failure name name
  let report ← check name property settings
  require (report.outcome == .failed && report.failures.size == 1) report.render
  for f in report.failures do
    for _ in [:2] do
      let replayed ← replay f.blob property settings
      require (replayed.status == .failed && replayed.origin == f.origin) "Replay changed failure"
      require (replayed.annotations == f.annotations) "Replay changed generated value"
      require ((← observed.get).any expected) s!"Unexpected minimum for {name}"
  IO.println s!"ok: {name} shrank and replayed twice"

inductive Tree where
  | leaf (value : Nat)
  | branch (left right : Tree)
  deriving Repr, Inhabited

def Tree.leaves : Tree → Nat
  | .leaf _ => 1
  | .branch a b => a.leaves + b.leaves

def Tree.depth : Tree → Nat
  | .leaf _ => 0
  | .branch a b => 1 + max a.depth b.depth

private def treeGen (depth leaves : Nat) : Gen Tree :=
  Gen.build <| Gen.maxDepth depth <| Gen.maxLeaves leaves <|
    Gen.Builder.recursive (.leaf <$> Gen.nat 0 100) fun ctx child => do
      Gen.assume (ctx.depth < ctx.maxDepth)
      return .branch (← child) (← child)

instance : Gen.Enumeration Bool := ⟨#[false, true]⟩
private instance : Gen.Enumeration Unit := ⟨#[]⟩

def run : IO Unit := do
  passes "generator/integer-widths" do
    let a ← draw Gen.int8
    let b ← draw Gen.int16
    let c ← draw Gen.int32
    let d ← draw Gen.int64
    let e ← draw Gen.uint8
    let f ← draw Gen.uint16
    let g ← draw Gen.uint32
    let h ← draw Gen.uint64
    let _ ← draw Gen.usize
    let _ ← draw Gen.isize
    assertThat (a.toInt ≥ -128 && b.toInt ≥ -32768 && c.toInt ≥ -2147483648 &&
      d.toInt ≥ -9223372036854775808) "signed bounds"
    assertThat (e.toNat < 2 ^ 8 && f.toNat < 2 ^ 16 && g.toNat < 2 ^ 32 &&
      h.toNat < 2 ^ 64) "unsigned bounds"
  passes "generator/typed-numeric-builders" do
    let n ← draw (Gen.build <| Gen.max (7 : Int8) <| Gen.min (-7 : Int8) Gen.Builder.int8)
    assertThat (-7 ≤ n && n ≤ 7) "int8 builder bounds"
    let u ← draw (Gen.build <| Gen.max (2 ^ 64 - 1 : UInt64) <|
      Gen.min (2 ^ 64 - 2 : UInt64) Gen.Builder.uint64)
    assertThat (u.toNat ≥ 2 ^ 64 - 2) "unsigned64 does not truncate"
    let yes ← draw (Gen.build <| Gen.weighted 1 Gen.Builder.bool)
    assertThat yes "weighted true"
  passes "generator/float32" do
    let config : Gen.FloatConfig := {
      min := -100, max := 100, allowNaN := false, allowInfinity := false }
    let n ← draw (Gen.float32 config)
    assertThat (!n.isNaN && n.toFloat ≥ -100 && n.toFloat ≤ 100) "float32 bounds"
    assertThat (n.toFloat.toFloat32.toBits == n.toBits) "float32 exact representation"
  passes "generator/float-builder-effective-flags" do
    let n ← draw (Gen.build <| Gen.exclusiveMin <| Gen.exclusiveMax <|
      Gen.max (1 : Float) <| Gen.min (0 : Float) Gen.Builder.float)
    assertThat (!n.isNaN && 0 < n && n < 1) "exclusive bounds exclude NaN and infinity"
  passes "generator/calendar-leap-days" do
    let d ← draw (Gen.date ⟨2024, 2, 28⟩ ⟨2024, 3, 1⟩)
    assertThat d.valid "valid leap calendar"
    assertThat (d.month == 2 || d.day == 1) "calendar bound"
    let ancient ← draw (Gen.date ⟨-999999, 1, 1⟩ ⟨-999999, 12, 31⟩)
    assertThat (ancient.valid && ancient.year == -999999) "negative year support"
  passes "generator/time-exact-nanoseconds" do
    let t ← draw (Gen.time ⟨12, 34, 56, 123456789⟩ ⟨12, 34, 56, 123456789⟩)
    assertEq t.nanosecond 123456789 "nanosecond precision"
  passes "generator/datetime-lexicographic-bounds" do
    let lo : DateTime := ⟨⟨2024, 2, 29⟩, ⟨23, 59, 59, 999999998⟩⟩
    let hi : DateTime := ⟨⟨2024, 3, 1⟩, ⟨0, 0, 0, 1⟩⟩
    let dt ← draw (Gen.datetime lo hi)
    assertThat (dt.valid && lo ≤ dt && dt ≤ hi) "lexicographic datetime bounds"
  passes "generator/year-and-day-builders" do
    let d ← draw (Gen.build <| Gen.minYear 2000 <| Gen.maxYear 2000 Gen.Builder.date)
    assertEq d.year 2000 "whole year"
    let dt ← draw (Gen.build <| Gen.onDay ⟨2024, 2, 29⟩ Gen.Builder.datetime)
    assertEq dt.date (Date.mk 2024 2 29) "one leap day"
  passes "generator/exact-picosecond-duration" do
    let n := 2 ^ 100 + 1
    let d ← draw (Gen.duration ⟨n⟩ ⟨n + 1⟩)
    assertThat (n ≤ d.picoseconds && d.picoseconds ≤ n + 1) "arbitrary precision duration"
    assertEq (Duration.hours 1).picoseconds (Duration.seconds 3600).picoseconds "duration units"
    let exact ← draw (Gen.duration ⟨1⟩ ⟨1⟩)
    assertEq exact.picoseconds 1 "one picosecond"
  passes "generator/fractional-duration-units" do
    assertEq (Duration.seconds 0.000000000001).picoseconds 1 "decimal one picosecond"
    assertEq (Duration.milliseconds 1.5).picoseconds 1500000000 "fractional milliseconds"
    assertEq (Duration.minutes (1 / 60)).picoseconds 1000000000000 "rational units"
    assertEq (Duration.exactSeconds? (1 / 3)) none "nonrepresentable exact fraction"
    assertEq (Duration.exactSeconds? (1 / 2)) (some ⟨500000000000⟩) "exact half second"
  passes "generator/uri-authority-components" do
    let text := "https://alice:p%40ss@[2001:db8::1]:00443/a%2fb?q=x#"
    let parsed := URI.parse text
    assertThat parsed.isSome "parse structured authority"
    if let some uri := parsed then
      assertEq uri.authority.userInfo (some "alice:p%40ss") "encoded user information"
      assertEq uri.authority.host "[2001:db8::1]" "IP literal host"
      assertEq uri.authority.port (some "00443") "explicit port spelling"
      assertEq uri.toString text "complete URI roundtrip"
    for invalid in ["https://a/%zz", "https://a/a b", "http://[not-ip]/", "https://a:bad/"] do
      assertEq (URI.parse invalid) none "reject invalid URI component syntax"
  passes "generator/uuid-version-and-variant" do
    for version in [0, 1, 4, 8, 15] do
      let uuid ← draw (Gen.uuid (some version))
      assertEq uuid.version version "version nibble"
      assertThat uuid.isRFCVariant "RFC variant"
      assertEq uuid.toString.length 36 "UUID formatting"
  passes "generator/parsed-uri-roundtrip" do
    let uri ← draw Gen.uri
    assertThat (uri.scheme == "http" || uri.scheme == "https") "URI scheme"
    assertThat (!uri.authority.host.isEmpty) "URI authority"
    assertEq (URI.parse uri.toString) (some uri) "URI parse/print"
  passes "generator/alphabet-presets" do
    let lower ← draw (Alphabet.lower.text 5 10)
    assertThat (lower.toList.all fun c => 'a' ≤ c && c ≤ 'z') "lowercase alphabet"
    let hex ← draw (Alphabet.hexit.text 10 10)
    assertThat (hex.toList.all fun c => "0123456789abcdefABCDEF".contains c) "hex alphabet"
    let alpha ← draw (Alphabet.alphaNum.text 10 10)
    assertThat (alpha.toList.all Char.isAlphanum) "category union"
    let latin ← draw (Alphabet.latin1.text 5 10)
    assertThat (latin.toList.all fun c => c.toNat < 256) "Latin1 codec"
  passes "generator/all-alphabet-presets" do
    let cases : Array (Alphabet × (Char → Bool)) := #[
      (Alphabet.ascii, fun c => c.toNat < 128),
      (Alphabet.asciiPrintable, fun c => 32 ≤ c.toNat && c.toNat ≤ 126),
      (Alphabet.upper, fun c => 'A' ≤ c && c ≤ 'Z'),
      (Alphabet.alpha, Char.isAlpha),
      (Alphabet.digit, Char.isDigit),
      (Alphabet.binit, fun c => "01".contains c),
      (Alphabet.octit, fun c => "01234567".contains c),
      (Alphabet.asciiPunctuation, fun c => "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains c),
      (Alphabet.base64, fun c => Char.isAlphanum c || "+/".contains c),
      (Alphabet.base64Url, fun c => Char.isAlphanum c || "-_".contains c),
      (Alphabet.uriUnreserved, fun c => Char.isAlphanum c || "-._~".contains c),
      (Alphabet.zeroWidth, fun c => [0x200b, 0x200c, 0x200d, 0x2060, 0xfeff].contains c.toNat),
      (Alphabet.bidiControls, fun c =>
        [0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
          0x2066, 0x2067, 0x2068, 0x2069].contains c.toNat),
      (Alphabet.whitespace, fun c => c.toNat ≤ 0x20 || c.toNat == 0x85 || c.toNat == 0xa0 ||
        c.toNat == 0x1680 || (0x2000 ≤ c.toNat && c.toNat ≤ 0x200a) ||
        [0x2028, 0x2029, 0x202f, 0x205f, 0x3000].contains c.toNat)]
    for (alphabet, accepts) in cases do
      assertThat (accepts (← draw alphabet.char)) "alphabet preset membership"
    let combining := { Alphabet.combiningMarks with
      minCodepoint := 0x300
      maxCodepoint := 0x36f }
    let mark ← draw combining.char
    assertThat (0x300 ≤ mark.toNat && mark.toNat ≤ 0x36f) "combining marks category"
    let scalar ← draw Alphabet.unicode.char
    assertThat (scalar.toNat < 0xd800 || scalar.toNat > 0xdfff) "Unicode excludes surrogates"
  passes "generator/alphabet-inclusion-exclusion-nul" do
    let a := { Alphabet.lower with includeCharacters := "0\x00", excludeCharacters := "a" }
    let value ← draw (a.text 5 10)
    assertThat (value.toList.all fun c => ('b' ≤ c && c ≤ 'z') || c == '0' || c == '\x00')
      "include and exclude precedence"
    let nul ← draw ((Alphabet.only "\x00").text 3 3)
    assertEq nul.utf8ByteSize 3 "embedded NUL length"
    let noNumbers : Alphabet := { codec := .ascii, excludeCategories := #[.Nd] }
    let chars ← draw (noNumbers.text 5 10)
    assertThat (chars.toList.all fun c => !c.isDigit) "category subtraction"
  passes "generator/regex-alphabet" do
    let text ← draw (Gen.build <| Gen.fullMatch <|
      Gen.alphabet Alphabet.lower (Gen.Builder.regex ".{3}"))
    assertThat (text.length == 3 && text.toList.all fun c => 'a' ≤ c && c ≤ 'z')
      "wildcards use configured alphabet"
  passes "generator/builder-text-and-binary" do
    let text ← draw (Gen.build <| Gen.minSize 7 <| Gen.maxSize 7 <|
      Gen.alphabet Alphabet.digit Gen.Builder.text)
    assertThat (text.length == 7 && text.toList.all Char.isDigit) "text builder"
    let bytes ← draw (Gen.build <| Gen.minSize 9 <| Gen.maxSize 9 Gen.Builder.binary)
    assertEq bytes.size 9 "binary builder"
  passes "generator/weighted-choices-enumerations" do
    let n ← draw (Gen.frequency #[(1, pure 3), (100, pure 7)])
    assertThat (n == 3 || n == 7) "weighted choice support"
    let _ ← draw (Gen.enumBounded (α := Bool))
    let c ← draw (Gen.enum #["a", "b", "c"] 1 2)
    assertThat (c == "b" || c == "c") "inclusive enumeration interval"
    let side ← draw (Gen.either (pure 42) (pure true))
    assertThat (match side with | .inl n => n == 42 | .inr b => b) "sum support"
  passes "generator/finite-filter-fast-path" do
    let rare := Gen.element (Array.range 10000)
    let one ← draw (Gen.filtered (· == 9999) rare)
    assertEq one 9999 "finite filter never discards a satisfiable choice"
    let n ← draw (Gen.just (Gen.element #[none, some 4]))
    assertEq n 4 "finite option mapping"
  require (Gen.enumerate ((· + 1) <$> Gen.element #[1, 2, 3]) == some [2, 3, 4])
    "mapped enumeration"
  passes "generator/nonempty-and-unique-list" do
    let xs ← draw (Gen.nonEmpty (Gen.nat 0 10) 1 3)
    assertThat (!xs.toList.isEmpty && xs.toList.length ≤ 3) "nonempty bounds"
    let unique ← draw (Gen.build <| Gen.minSize 3 <| Gen.maxSize 3 <|
      Gen.unique (· == ·) (Gen.Builder.list (Gen.nat 0 10)))
    assertThat (unique.length == 3 && unique.eraseDups.length == 3) "fixed unique length"
  passes "generator/map-skips-duplicate-values" do
    let count ← io (IO.mkRef 0)
    let values : Gen Nat := Gen.ofRun fun _ => do
      count.modify (· + 1)
      count.get
    let pairs ← draw (Gen.entries (· == ·) (Gen.element #[0, 1]) values 2 2)
    assertEq pairs.size 2 "two distinct keys"
    assertEq (← io count.get) 2 "duplicate keys never draw a value"
  let overshoots ← IO.mkRef 0
  passes "generator/ordered-collection-overshoot" do
    let count ← io (IO.mkRef 0)
    let keys : Gen Nat := Gen.ofRun fun _ => do
      let n ← count.get
      count.modify (· + 1)
      return if n == 0 then 100 else 0
    let result ← draw (Gen.map keys (pure true) 1 1)
    let used ← io count.get
    assertEq result.size 1 "trim fixed-size map"
    if used > 1 then
      io (overshoots.modify (· + 1))
      assertThat (result.contains 0) "overshoot retains the smallest key"
    else assertThat (result.contains 100) "one drawn key is retained"
  require ((← overshoots.get) > 0) "Ordered map test never exercised overshoot"
  passes "generator/mapMaybe-propagates-source-discard" do
    let count ← io (IO.mkRef 0)
    let source : Gen Nat := Gen.ofRun fun _ => do
      count.modify (· + 1)
      throw Abort.discard
    let recovered : Gen Bool := Gen.ofRun fun session => do
      match ← ((Gen.mapMaybe some source) session).toBaseIO with
      | .error .discard => return true
      | _ => return false
    assertThat (← draw recovered) "source discard is preserved"
    assertEq (← io count.get) 1 "source discard is not retried"
  passes "generator/unbounded-builders" do
    let xs ← draw (Gen.build <| Gen.Builder.set (Gen.nat 0 100))
    assertThat (xs.size ≤ 101) "default unbounded set builder"
    let ys ← draw (Gen.build <| Gen.Builder.list (Gen.nat 0 10))
    assertThat (ys.all (· ≤ 10)) "default unbounded list builder"
  passes "generator/sets-and-maps" do
    let set ← draw (Gen.set (Gen.nat 0 100) 5 5)
    let hashed ← draw (Gen.hashSet (Gen.nat 0 100) 5 5)
    let ints ← draw (Gen.intSet (Gen.int (-100) 100) 5 5)
    assertThat (set.size == 5 && hashed.size == 5 && ints.size == 5) "set sizes"
    let map ← draw (Gen.map (Gen.nat 0 100) (Gen.bool) 5 5)
    let hashMap ← draw (Gen.hashMap (Gen.nat 0 100) (Gen.bool) 5 5)
    let intMap ← draw (Gen.intMap (Gen.int (-100) 100) (Gen.bool) 5 5)
    assertThat (map.size == 5 && hashMap.size == 5 && intMap.size == 5) "map key uniqueness"
  passes "generator/native-recursion-budgets" do
    let tree ← draw (treeGen 5 7)
    assertThat (tree.depth ≤ 5 && tree.leaves ≤ 7) "shared leaf and depth budgets"
    let leaf ← draw (treeGen 0 1)
    assertThat (leaf.depth == 0 && leaf.leaves == 1) "zero depth is a leaf"
  let branchAttempts ← IO.mkRef 0
  let oversized : Gen Nat := Gen.build <| Gen.maxLeaves 3 <| Gen.maxDepth 8 <|
    Gen.Builder.recursive (pure 1) fun _ child => Gen.ofRun fun session => do
      branchAttempts.modify (· + 1)
      let a ← child session
      let b ← child session
      let c ← child session
      let d ← child session
      let e ← child session
      return a + b + c + d + e
  passes "generator/native-recursion-overflow-retry" do
    assertEq (← draw oversized) 1 "five-child branches cannot fit a three-leaf budget"
  require ((← branchAttempts.get) > 0) "Recursion test never exercised an oversized branch"
  passes "generator/native-recursion-zero-arity" do
    let value ← draw (Gen.build <| Gen.maxLeaves 10 <|
      Gen.Builder.recursive (pure 1) fun _ _ => pure 0)
    assertThat (value == 0 || value == 1) "branch constructors may have no child draws"
  shrinks "generator/date-shrinks-to-year-2000" (Gen.date) (· == Date.mk 2000 1 1)
  shrinks "generator/time-shrinks-to-lower-bound" (Gen.time ⟨12, 0, 0, 0⟩ .endOfDay)
    (· == Time.mk 12 0 0 0)
  shrinks "generator/datetime-shrinks-to-year-2000" (Gen.datetime)
    (· == DateTime.mk ⟨2000, 1, 1⟩ .midnight)
  shrinks "generator/duration-shrinks-to-zero" (Gen.duration) (·.picoseconds == 0)
  shrinks "generator/recursive-shrinks-to-one-leaf" (treeGen 8 30) (·.leaves == 1)
  rejects "generator/invalid-leap-day" do let _ ← draw (Gen.date ⟨2023, 2, 29⟩); pure ()
  rejects "generator/invalid-time" do let _ ← draw (Gen.time ⟨24, 0, 0, 0⟩); pure ()
  rejects "generator/negative-duration" do let _ ← draw (Gen.duration ⟨-1⟩); pure ()
  rejects "generator/invalid-uuid-version" do let _ ← draw (Gen.uuid (some 16)); pure ()
  rejects "generator/zero-frequency-weight" do let _ ← draw (Gen.frequency #[(0, pure 1)]); pure ()
  rejects "generator/negative-builder-size" do
    let _ ← draw (Gen.build <| Gen.minSize (-1) Gen.Builder.binary)
    pure ()
  rejects "generator/empty-alphabet" do let _ ← draw ((Alphabet.only "").char); pure ()
  rejects "generator/empty-enumeration" do
    let _ ← draw (Gen.enumBounded (α := Unit))
    pure ()
  rejects "generator/inverted-integral-builder" do
    let _ ← draw (Gen.build <| Gen.Builder.integer 10 0)
    pure ()
  rejects "generator/inverted-nonempty-bounds" do
    let _ ← draw (Gen.nonEmpty (pure 0) 3 2)
    pure ()
  rejects "generator/conflicting-categories" do
    let a : Alphabet := { categories := some #[.Lu], excludeCategories := #[.Ll] }
    let _ ← draw a.char
    pure ()

end Tests.Generators
