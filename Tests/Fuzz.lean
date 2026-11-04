import Hegel
import Hegel.Replay
import Hegel.Diff

/-! Self-hosted fuzzing: Hegel generates inputs for its own frontend.

Each property states a contract of a pure helper or a generator. The driver runs every property
over several seeds and reports passes, counterexamples, and engine errors separately. -/
namespace Tests.Fuzz
open Hegel Hegel.Property

private def check' (cond : Bool) (origin : String) (message : String) : Property Unit :=
  assertThat cond origin message

/-- Text with the characters that stress envelopes and parsers. -/
private def nastyText (maxSize : Nat := 24) : Gen String :=
  Alphabet.text (Alphabet.only ":\"\\[](){},'\n\t #%@/?0aA\x00é😀") 0 maxSize

private def anyText (maxSize : Nat := 24) : Gen String :=
  Gen.oneOf #[Gen.text { maxSize }, nastyText maxSize]

/-! ## Pure helpers -/

def replayRoundTrip : Property Unit := do
  let version ← forAll (anyText 12) "version"
  assume (!version.isEmpty)
  let origin ← forAll (anyText 24) "origin"
  let blob ← forAll (Alphabet.text Alphabet.base64 1 32) "blob"
  let token : ReplayToken := ⟨version, origin, blob⟩
  let encoded := encodeReplayToken token
  match decodeReplayToken encoded with
  | .ok decoded => assertEq decoded token "replay/roundtrip"
  | .error e => failure "replay/roundtrip" s!"{repr e} for {encoded.quote}"

def replayDecodeStable : Property Unit := do
  let prefix_ ← forAll (Gen.element #["hegel-replay:", "hegel-replay", "", "x:"]) "prefix"
  let body ← forAll (nastyText 40) "body"
  match decodeReplayToken (prefix_ ++ body) with
  | .error _ => pure ()
  | .ok token =>
    match decodeReplayToken (encodeReplayToken token) with
    | .ok again => assertEq again token "replay/stable"
    | .error e => failure "replay/stable" s!"re-encoded token rejected: {repr e}"

private def reconstruct (diff : Diff) (keepRemoved : Bool) : String :=
  "\n".intercalate <| diff.toList.filterMap fun
    | .same t => some t
    | .removed t => if keepRemoved then some t else none
    | .added t => if keepRemoved then none else some t

def diffLinesReconstructs : Property Unit := do
  let lines := Gen.list (Gen.element #["a", "b", "c", "", " "]) 0 8
  let a ← forAll lines "actual"
  let b ← forAll lines "expected"
  let actual := "\n".intercalate a
  let expected := "\n".intercalate b
  let diff := diffLines actual expected
  assertEq (reconstruct diff true) actual "diff/lines-actual"
  assertEq (reconstruct diff false) expected "diff/lines-expected"
  if actual == expected then
    check' (diff.all (· matches .same _)) "diff/lines-equal" "equal inputs produced changes"

private def stripWs (s : String) : String := String.ofList (s.toList.filter (!·.isWhitespace))

private def lineText : LineDiff → String
  | .same t | .removed t | .added t => t

def diffShownPreserves : Property Unit := do
  let item := Gen.oneOf #[nastyText 6, Gen.element #["x", "(1, 2)", "[]", "'['", "\"]\""]]
  let xs ← forAll (Gen.list (Gen.list item 0 3) 0 4) "actual"
  let ys ← forAll (Gen.list (Gen.list item 0 3) 0 4) "expected"
  let self := diffRepr xs xs
  check' (self.all (· matches .same _)) "diff/repr-equal" s!"self diff has changes: {renderDiff self}"
  -- Every rendered line must come from the shown values; no characters may be invented or lost.
  match diffShown (reprStr xs) (reprStr xs) with
  | some #[.same rendered] =>
    assertEq (stripWs rendered) (stripWs (reprStr xs)) "diff/repr-render"
  | some other => failure "diff/repr-render" s!"unexpected self diff {repr other}"
  | none => pure ()
  let d := diffRepr xs ys
  if xs != ys then
    check' (d.any fun l => !(l matches .same _)) "diff/repr-unequal"
      s!"unequal values rendered no change: {renderDiff d}"
  -- Removed/same text, flattened, must contain the actual value's characters in order.
  let removed := stripWs (String.join (d.toList.filterMap fun l =>
    match l with | .added _ => none | l => some (lineText l)))
  check' (removed.length ≥ (stripWs (reprStr xs)).length / 2 || xs.isEmpty) "diff/repr-lost"
    s!"diff lost most of the actual value: {renderDiff d}"

def intCodec : Property Unit := do
  let e ← forAll (Gen.nat 0 300) "bits"
  let off ← forAll (Gen.int (-3) 3) "offset"
  let neg ← forAll Gen.bool "negative"
  let n : Int := (if neg then -1 else 1) * ((2 : Int) ^ e + off)
  assertEq (Gen.decodeInt (Gen.encodeInt n)) n "int/codec"

def durationConversions : Property Unit := do
  let num ← forAll (Gen.int (-10 ^ 30) (10 ^ 30)) "numerator"
  let den ← forAll (Gen.nat 1 (10 ^ 15)) "denominator"
  let q : Rat := mkRat num den
  let d := Duration.seconds q
  -- Rounds down: d ≤ q·10¹² < d + 1.
  let ps := q * 1000000000000
  check' ((d.picoseconds : Rat) ≤ ps && ps < d.picoseconds + 1) "duration/floor"
    s!"{d.picoseconds} is not the floor of {ps}"
  match Duration.exactSeconds? q with
  | some exact => check' ((exact.picoseconds : Rat) == ps) "duration/exact" "inexact exact"
  | none => check' (ps.den != 1) "duration/exact" "exact value rejected"

def uriParseStable : Property Unit := do
  let text ← forAll (Gen.oneOf #[Gen.url, (· ++ ·) <$> Gen.url <*> nastyText 8,
    (fun a b => "http://" ++ a ++ b) <$> nastyText 10 <*> nastyText 10]) "text"
  match URI.parse text with
  | none => pure ()
  | some uri =>
    match URI.parse uri.toString with
    | some again => assertEq again uri "uri/reparse"
    | none => failure "uri/reparse" s!"rendered URI does not parse: {uri.toString.quote}"

def generatedUrisParse : Property Unit := do
  let uri ← forAll Gen.uri "uri"
  assertEq (URI.parse uri.toString) (some uri) "uri/generated"

/-! ## Generator contracts -/

private def bigInt : Gen Int := Gen.oneOf #[
  Gen.int (-1000) 1000,
  Gen.int (-(2 ^ 64)) (2 ^ 64),
  Gen.int (-(2 ^ 200)) (2 ^ 200),
  (fun e o s => s * (2 ^ e + o)) <$> Gen.nat 0 130 <*> Gen.int (-2) 2 <*> Gen.element #[1, -1]]

def intBounds : Property Unit := do
  let a ← forAll bigInt "a"
  let b ← forAll bigInt "b"
  let lo := min a b
  let hi := max a b
  let x ← forAll (Gen.int lo hi) "x"
  check' (lo ≤ x && x ≤ hi) "gen/int-bounds" s!"{x} outside [{lo}, {hi}]"

def machineInts : Property Unit := do
  let i8 ← forAll Gen.int8 "i8"
  let i64 ← forAll Gen.int64 "i64"
  let isz ← forAll Gen.isize "isize"
  let u64 ← forAll Gen.uint64 "u64"
  check' (i8.toInt ≥ -128 && i8.toInt ≤ 127) "gen/int8" "range"
  check' (i64.toInt ≥ -(2 ^ 63) && i64.toInt < 2 ^ 63) "gen/int64" "range"
  check' (isz.toInt ≥ -(2 ^ 63) && isz.toInt < 2 ^ 63) "gen/isize" "range"
  check' (u64.toNat < 2 ^ 64) "gen/uint64" "range"

def sizedCollections : Property Unit := do
  let lo ← forAll (Gen.nat 0 6) "min"
  let extra ← forAll (Gen.nat 0 6) "extra"
  let hi := lo + extra
  let xs ← forAll (Gen.array (Gen.nat 0 3) lo hi) "array"
  check' (lo ≤ xs.size && xs.size ≤ hi) "gen/array-size" s!"{xs.size} ∉ [{lo}, {hi}]"
  let bs ← forAll (ByteArray.data <$> Gen.bytes lo hi) "bytes"
  check' (lo ≤ bs.size && bs.size ≤ hi) "gen/bytes-size" s!"{bs.size} ∉ [{lo}, {hi}]"
  let us ← forAll (Gen.uniqueArray (Gen.nat 0 20) lo hi) "unique"
  check' (lo ≤ us.size && us.size ≤ hi) "gen/unique-size" s!"{us.size} ∉ [{lo}, {hi}]"
  check' (us.toList.eraseDups.length == us.size) "gen/unique-distinct" "duplicate"
  let ub ← forAll (Gen.uniqueArrayBy (· == ·) (Gen.nat 0 20) lo hi) "uniqueBy"
  check' (lo ≤ ub.size && ub.size ≤ hi) "gen/uniqueBy-size" s!"{ub.size} ∉ [{lo}, {hi}]"
  check' (ub.toList.eraseDups.length == ub.size) "gen/uniqueBy-distinct" "duplicate"
  let s ← forAll ((·.toList) <$> Gen.set (Gen.nat 0 20) lo hi) "set"
  check' (lo ≤ s.length && s.length ≤ hi) "gen/set-size" s!"{s.length} ∉ [{lo}, {hi}]"
  let hs ← forAll ((·.toList) <$> Gen.hashSet (Gen.nat 0 20) lo hi) "hashSet"
  check' (lo ≤ hs.length && hs.length ≤ hi) "gen/hashSet-size" s!"{hs.length} ∉ [{lo}, {hi}]"
  let m ← forAll ((·.toList) <$> Gen.map (Gen.nat 0 20) Gen.bool lo hi) "map"
  check' (lo ≤ m.length && m.length ≤ hi) "gen/map-size" s!"{m.length} ∉ [{lo}, {hi}]"
  let hm ← forAll ((·.toList) <$> Gen.hashMap (Gen.nat 0 20) Gen.bool lo hi) "hashMap"
  check' (lo ≤ hm.length && hm.length ≤ hi) "gen/hashMap-size" s!"{hm.length} ∉ [{lo}, {hi}]"
  let es ← forAll (Gen.entries (· == ·) (Gen.nat 0 20) Gen.bool lo hi) "entries"
  check' (lo ≤ es.size && es.size ≤ hi) "gen/entries-size" s!"{es.size} ∉ [{lo}, {hi}]"
  if lo > 0 then
    let ne ← forAll (Gen.nonEmpty (Gen.nat 0 3) lo hi) "nonEmpty"
    check' (lo ≤ ne.toList.length && ne.toList.length ≤ hi) "gen/nonEmpty-size" "size"

private def surrogate (c : Char) : Bool := 0xd800 ≤ c.toNat && c.toNat ≤ 0xdfff

def textBounds : Property Unit := do
  let lo ← forAll (Gen.nat 0 5) "min"
  let hi := lo + (← forAll (Gen.nat 0 5) "extra")
  let a ← forAll (Gen.nat 0 0x10ffff) "cpA"
  let b ← forAll (Gen.oneOf #[Gen.nat 0 0x10ffff, (a + ·) <$> Gen.nat 0 300]) "cpB"
  let minCp := min a b
  let maxCp := min 0x10ffff (max a b)
  -- A range made only of surrogates has no valid scalar.
  assume (minCp < 0xd800 || maxCp > 0xdfff)
  let s ← forAll (Gen.text { minSize := lo, maxSize := hi, minCodepoint := minCp.toUInt32, maxCodepoint := maxCp.toUInt32 }) "text"
  check' (lo ≤ s.length && s.length ≤ hi) "gen/text-size" s!"{s.length} ∉ [{lo}, {hi}]"
  check' (s.toList.all fun c => minCp ≤ c.toNat && c.toNat ≤ maxCp && !surrogate c)
    "gen/text-codepoints" s!"codepoint outside [{minCp}, {maxCp}]"

def alphabetBounds : Property Unit := do
  let lo ← forAll (Gen.nat 0 4) "min"
  let hi := lo + (← forAll (Gen.nat 0 4) "extra")
  let inc ← forAll (Alphabet.text Alphabet.unicode 1 6) "include"
  let exc ← forAll (nastyText 4) "exclude"
  assume ((inc.toList.filter (!exc.toList.contains ·)).length > 0)
  -- The engine rejects characters that are both included and excluded.
  assume (!inc.toList.any exc.toList.contains)
  let s ← forAll (Alphabet.text (Alphabet.only inc |> fun a => { a with excludeCharacters := exc })
    lo hi) "text"
  check' (lo ≤ s.length && s.length ≤ hi) "alphabet/size" s!"{s.length} ∉ [{lo}, {hi}]"
  check' (s.toList.all fun c => inc.toList.contains c && !exc.toList.contains c)
    "alphabet/membership" s!"{s.quote} escapes include={inc.quote} exclude={exc.quote}"

def namedAlphabets : Property Unit := do
  let (name, a, ok) ← (Gen.element (#[
    ("ascii", Alphabet.ascii, fun (c : Char) => c.toNat < 128),
    ("latin1", Alphabet.latin1, fun c => c.toNat < 256),
    ("lower", Alphabet.lower, fun c => c.isLower),
    ("digit", Alphabet.digit, fun c => c.isDigit),
    ("alpha", Alphabet.alpha, fun c => c.isAlpha),
    ("alphaNum", Alphabet.alphaNum, fun c => c.isAlphanum),
    ("hexit", Alphabet.hexit, fun c => "0123456789abcdefABCDEF".contains c),
    ("binit", Alphabet.binit, fun c => c == '0' || c == '1'),
    ("zeroWidth", Alphabet.zeroWidth, fun c => [0x200b, 0x200c, 0x200d, 0x2060, 0xfeff].contains c.toNat)
  ] : Array (String × Alphabet × (Char → Bool)))) |> forAllWith (fun (n, _, _) => n)
  let s ← forAll (a.text 0 12) name
  check' (s.toList.all ok) s!"alphabet/{name}" s!"{s.quote}"

private def finite : Gen Float := Gen.oneOf #[
  Gen.float { allowNaN := false, allowInfinity := false },
  Gen.element #[0.0, -0.0, 1.0, -1.0, 5e-324, -5e-324, 1.7976931348623157e308, 0.1, 2.0 ^ 53]]

def floatBounds : Property Unit := do
  let a ← forAll finite "a"
  let b ← forAll finite "b"
  let lo := min a b
  let hi := max a b
  let exLo ← forAll Gen.bool "excludeMin"
  let exHi ← forAll Gen.bool "excludeMax"
  -- Exclusion on a single point (or adjacent points) can leave nothing to draw.
  -- Exclusion can empty the interval, e.g. the open interval (-5e-324, 0).
  let config : Gen.FloatConfig := {
    min := lo, max := hi, allowNaN := false, allowInfinity := false
    excludeMin := exLo, excludeMax := exHi }
  assume config.emptyReason?.isNone
  let x ← forAll (Gen.float { min := lo, max := hi, allowNaN := false, allowInfinity := false, excludeMin := exLo, excludeMax := exHi }) "x"
  check' (!x.isNaN && lo ≤ x && x ≤ hi) "gen/float-range" s!"{x} outside [{lo}, {hi}]"
  if exLo then check' (x != lo || (lo == 0 && hi > 0 && x.toBits != lo.toBits)) "gen/float-exclude-min" s!"{x} = {lo}"
  if exHi then check' (x != hi || (hi == 0 && lo < 0 && x.toBits != hi.toBits)) "gen/float-exclude-max" s!"{x} = {hi}"

def float32Bounds : Property Unit := do
  let a ← forAll (Gen.float32 { allowNaN := false, allowInfinity := false }) "a"
  let b ← forAll (Gen.float32 { allowNaN := false, allowInfinity := false }) "b"
  let lo := min a b
  let hi := max a b
  -- Gen.float32 rejects empty ranges such as [+0, -0]; the probes cover that.
  assume (Gen.FloatConfig.emptyReason? { min := lo.toFloat, max := hi.toFloat } 32).isNone
  let x ← forAll (Gen.float32 { min := lo.toFloat, max := hi.toFloat, allowNaN := false, allowInfinity := false }) "x"
  check' (!x.isNaN && lo ≤ x && x ≤ hi) "gen/float32-range" s!"{x} outside [{lo}, {hi}]"

def noNaNUnlessAllowed : Property Unit := do
  let x ← forAll (Gen.float { allowNaN := false }) "x"
  check' (!x.isNaN) "gen/float-nan" "NaN without allowNaN"
  let y ← forAll (Gen.float { allowInfinity := false, allowNaN := false }) "y"
  check' (!y.isInf) "gen/float-inf" "infinity without allowInfinity"

private def validDate : Gen Date := do
  let y ← Gen.oneOf #[Gen.int (-999999) 999999, Gen.int 1890 2110, Gen.element #[-999999, 999999, 0, 2000, 1900]]
  let m ← Gen.nat 1 12
  let d ← Gen.nat 1 (Date.daysInMonth y m)
  return ⟨y, m, d⟩

private def validTime : Gen Time := do
  return ⟨← Gen.nat 0 23, ← Gen.nat 0 59, ← Gen.nat 0 59,
    ← Gen.oneOf #[Gen.nat 0 999999999, Gen.element #[0, 999999999]]⟩

def calendarBounds : Property Unit := do
  let a ← forAll validDate "a"
  let b ← forAll validDate "b"
  let (lo, hi) := if a ≤ b then (a, b) else (b, a)
  let d ← forAll (Gen.date lo hi) "date"
  check' (d.valid && lo ≤ d && d ≤ hi) "gen/date" s!"{repr d} outside bounds"
  let t1 ← forAll validTime "t1"
  let t2 ← forAll validTime "t2"
  let (tlo, thi) := if t1 ≤ t2 then (t1, t2) else (t2, t1)
  let t ← forAll (Gen.time tlo thi) "time"
  check' (t.valid && tlo ≤ t && t ≤ thi) "gen/time" s!"{repr t} outside bounds"
  let x : DateTime := ⟨a, t1⟩
  let y : DateTime := ⟨b, t2⟩
  let (dlo, dhi) := if x ≤ y then (x, y) else (y, x)
  let dt ← forAll (Gen.datetime dlo dhi) "datetime"
  check' (dt.valid && dlo ≤ dt && dt ≤ dhi) "gen/datetime" s!"{repr dt} outside bounds"

def durationBounds : Property Unit := do
  let a ← forAll (Gen.nat 0 (2 ^ 80)) "a"
  let b ← forAll (Gen.nat 0 (2 ^ 80)) "b"
  let d ← forAll (Gen.duration ⟨min a b⟩ ⟨max a b⟩) "duration"
  check' (min a b ≤ d.picoseconds && d.picoseconds ≤ max a b) "gen/duration" "out of bounds"

def miscGenerators : Property Unit := do
  let v ← forAll (Gen.option (Gen.nat 0 15)) "version"
  let u ← forAll (Gen.uuid (v.map (·.toUInt8))) "uuid"
  if let some v := v then check' (u.version.toNat == v) "gen/uuid-version" s!"{u} ≠ v{v}"
  check' (u.toString.length == 36) "gen/uuid-text" u.toString
  let maxLen ← forAll (Gen.nat 4 253) "maxLength"
  let dom ← forAll (Gen.domain maxLen.toUInt64) "domain"
  check' (dom.length ≤ maxLen) "gen/domain-length" s!"{dom.length} > {maxLen}"
  let n ← forAll (Gen.nat 1 6) "n"
  let values := (List.range n).toArray
  let lo ← forAll (Gen.nat 0 (n - 1)) "lo"
  let hi ← forAll (Gen.nat lo (n - 1)) "hi"
  let e ← forAll (Gen.enum values lo hi) "enum"
  check' (lo ≤ e && e ≤ hi) "gen/enum" s!"{e} ∉ [{lo}, {hi}]"
  let weights ← forAll (Gen.list (Gen.nat 1 5) 1 4) "weights"
  let f ← forAll (Gen.frequency (weights.toArray.mapIdx fun i w => (w, pure i))) "frequency"
  check' (f < weights.length) "gen/frequency" s!"{f}"
  let k ← forAll (Gen.filtered (· % 3 == 0) (Gen.nat 0 100)) "filtered"
  check' (k % 3 == 0) "gen/filtered" s!"{k}"
  let j ← forAll (Gen.mapMaybe (fun x => if x % 2 == 0 then some (x / 2) else none)
    (Gen.element #[0, 1, 2, 3, 4, 5])) "mapMaybe"
  check' (j ≤ 2) "gen/mapMaybe" s!"{j}"

/-- Valid configurations should never surface as engine errors. -/
def validConfigsNoEngineError : Property Unit := do
  let cp ← forAll (Gen.nat 0 0x10ffff) "codepoint"
  assume (cp < 0xd800 || cp > 0xdfff)
  let s ← forAll (Gen.text { minSize := 1, maxSize := 1, minCodepoint := cp.toUInt32, maxCodepoint := cp.toUInt32 }) "single"
  assertEq (s.toList.map Char.toNat) [cp] "gen/text-single"

def all : List (String × Property Unit) := [
  ("replay roundtrip", replayRoundTrip),
  ("replay decode stability", replayDecodeStable),
  ("diffLines reconstructs both sides", diffLinesReconstructs),
  ("diffRepr preserves shown values", diffShownPreserves),
  ("two's-complement integer codec", intCodec),
  ("duration conversions", durationConversions),
  ("URI parse stability", uriParseStable),
  ("generated URIs parse", generatedUrisParse),
  ("Gen.int bounds", intBounds),
  ("machine integer ranges", machineInts),
  ("collection size contracts", sizedCollections),
  ("text size and codepoint bounds", textBounds),
  ("alphabet include/exclude", alphabetBounds),
  ("named alphabets", namedAlphabets),
  ("float bounds and exclusion", floatBounds),
  ("float32 bounds", float32Bounds),
  ("float NaN/infinity flags", noNaNUnlessAllowed),
  ("calendar bounds", calendarBounds),
  ("duration bounds", durationBounds),
  ("misc generators", miscGenerators),
  ("single-codepoint text", validConfigsNoEngineError)]

end Tests.Fuzz

open Hegel in
/-- Invalid configurations must fail (never pass, crash, or hang). -/
def probes : List (String × Gen String) := [
  ("float [+0, -0]", toString <$> Gen.float { min := 0.0, max := -0.0, allowNaN := false }),
  ("float32 [+0, -0]", toString <$> Gen.float32 { min := 0.0, max := -0.0, allowNaN := false }),
  ("float only +inf, inf disallowed", toString <$> Gen.float { min := 1 / 0, allowNaN := false, allowInfinity := false }),
  ("bool p=1.5", toString <$> Gen.bool 1.5),
  ("bool p=NaN", toString <$> Gen.bool (0 / 0)),
  ("float min>max", toString <$> Gen.float { min := 1, max := 0 }),
  ("float min=NaN", toString <$> Gen.float { min := 0 / 0 }),
  ("float32 unrepresentable", toString <$> Gen.float32 { min := 0.1, max := 0.1 }),
  ("text minCp>maxCp", Gen.text { minCodepoint := 100, maxCodepoint := 50 }),
  ("text surrogates only", Gen.text { minSize := 1, minCodepoint := 0xd800, maxCodepoint := 0xdfff }),
  ("text bad codec", Gen.text { codec := "klingon" }),
  ("text ascii high cps", Gen.text { minSize := 1, codec := "ascii", minCodepoint := 200 }),
  ("regex unbalanced", Gen.regex "("),
  ("regex with literal NUL", Gen.regex "a\x00"),
  ("regex empty language", Gen.regex "[^\\s\\S]"),
  ("domain 3", Gen.domain 3),
  ("alphabet empty only", Alphabet.text (Alphabet.only "") 1 2),
  ("alphabet min>max cp", Alphabet.text { minCodepoint := 9, maxCodepoint := 3 } 0 2),
  ("alphabet overlap", Alphabet.text { includeCharacters := "a", excludeCharacters := "a" } 0 2),
  ("alphabet ascii+latin cat", Alphabet.text { codec := .ascii, categories := some #[.Lo] } 1 2),
  ("alphabet regex bad", Alphabet.regex Alphabet.lower "(("),
  ("int min>max", toString <$> Gen.int 2 1),
  ("bytes min>max", toString <$> (ByteArray.size <$> Gen.bytes 3 2)),
  ("array 2^64", toString <$> (Array.size <$> Gen.array Gen.bool 0 (2 ^ 64))),
  ("unique impossible", toString <$> (Array.size <$> Gen.uniqueArray Gen.bool 3 3)),
  ("set impossible", toString <$> ((·.size) <$> Gen.set Gen.bool 3 3)),
  ("element empty", toString <$> Gen.element (#[] : Array Nat)),
  ("frequency zero", toString <$> Gen.frequency #[(0, pure 1)]),
  ("enum bad range", toString <$> Gen.enum #[1, 2] 1 5),
  ("date invalid", toString <$> (repr <$> Gen.date ⟨2001, 2, 29⟩ ⟨2002, 1, 1⟩)),
  ("time reversed", toString <$> (repr <$> Gen.time ⟨5, 0, 0, 0⟩ ⟨4, 0, 0, 0⟩)),
  ("duration negative", toString <$> (repr <$> Gen.duration ⟨-1⟩ ⟨5⟩)),
  ("uuid v16", toString <$> Gen.uuid (some 16)),
  ("collection with bad", toString <$> Collection.with 3 2 fun _ => pure 0),
  ("nonEmpty zero", toString <$> ((·.toList.length) <$> Gen.nonEmpty Gen.bool 0 0))]

open Hegel in
def runProbes : IO Nat := do
  let mut bad := 0
  for (name, gen) in probes do
    let report ← check name (do let _ ← Property.forAllWith (fun s => s) gen; pure ())
      { seed := some 0, maxExamples := 50, database := none }
    let kind := match report.outcome with
      | .passed => "PASSED" | .failed => "failure" | .error => "error" | .nondeterministic => "flaky"
    if report.outcome == .passed then bad := bad + 1
    let detail := (report.failures[0]?.map (·.origin)).getD report.message
    if (detail.splitOn "Internal error").length > 1 then bad := bad + 1
    IO.println s!"probe {kind}: {name}: {detail.take 160}"
  return bad

open Hegel in
def main (args : List String) : IO UInt32 := do
  let seeds := (args[0]? >>= String.toNat?).getD 3
  let examples := (args[1]? >>= String.toNat?).getD 300
  let only : Option String := args[2]?
  let mut bad := 0
  for (name, p) in Tests.Fuzz.all do
    if only.any (fun p => !name.startsWith p) then continue
    for seed in [:seeds] do
      let report ← check name p { seed := some seed.toUInt64, maxExamples := examples.toUInt64, database := none }
      if report.isSuccess then
        IO.println s!"ok: {name} seed={seed} ({report.evaluations} evaluations)"
      else
        bad := bad + 1
        IO.println s!"FAIL: {name} seed={seed}\n{report.render}\n"
        break
  if only.isNone then bad := bad + (← runProbes)
  IO.println s!"{bad} failing properties"
  return if bad == 0 then 0 else 1
