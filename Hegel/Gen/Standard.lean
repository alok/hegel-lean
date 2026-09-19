import Hegel.Alphabet
import Init.Data.Rat
import Std.Net.Addr
import Std.Data.TreeMap
import Std.Data.TreeSet
import Std.Data.HashMap
import Std.Data.HashSet

namespace Hegel

/-- A proleptic Gregorian date; generators validate every field and leap day. -/
structure Date where
  year : Int
  month : Nat
  day : Nat
  deriving Repr, BEq, Inhabited

namespace Date

def leapYear (year : Int) : Bool := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
def daysInMonth (year : Int) : Nat → Nat
  | 2 => if leapYear year then 29 else 28
  | 4 | 6 | 9 | 11 => 30
  | _ => 31

def valid (d : Date) : Bool :=
  -999999 ≤ d.year && d.year ≤ 999999 && 1 ≤ d.month && d.month ≤ 12 &&
  1 ≤ d.day && d.day ≤ daysInMonth d.year d.month

def compare (a b : Date) : Ordering :=
  (Ord.compare a.year b.year).then ((Ord.compare a.month b.month).then (Ord.compare a.day b.day))
instance : Ord Date := ⟨compare⟩
instance : LE Date := ⟨fun a b => compare a b ≠ .gt⟩
instance (a b : Date) : Decidable (a ≤ b) := inferInstanceAs (Decidable (compare a b ≠ .gt))
def fields (d : Date) : Array Int := #[d.year, d.month, d.day]
def fromFields (a : Array Int) : Option Date := do
  let y ← a[0]?
  let m ← a[1]?
  let d ← a[2]?
  let result := Date.mk y m.toNat d.toNat
  if m < 0 || d < 0 || !result.valid then none else some result
end Date

/-- A time of day with exact nanoseconds and no leap-second representation. -/
structure Time where
  hour : Nat := 0
  minute : Nat := 0
  second : Nat := 0
  nanosecond : Nat := 0
  deriving Repr, BEq, Inhabited

namespace Time

def valid (t : Time) : Bool :=
  t.hour < 24 && t.minute < 60 && t.second < 60 && t.nanosecond < 1000000000
def compare (a b : Time) : Ordering :=
  (Ord.compare a.hour b.hour).then ((Ord.compare a.minute b.minute).then
    ((Ord.compare a.second b.second).then (Ord.compare a.nanosecond b.nanosecond)))
instance : Ord Time := ⟨compare⟩
instance : LE Time := ⟨fun a b => compare a b ≠ .gt⟩
instance (a b : Time) : Decidable (a ≤ b) := inferInstanceAs (Decidable (compare a b ≠ .gt))
def midnight : Time := {}
def endOfDay : Time := ⟨23, 59, 59, 999999999⟩
def fields (t : Time) : Array Int := #[t.hour, t.minute, t.second, t.nanosecond]
def fromFields (a : Array Int) : Option Time := do
  let h ← a[0]?
  let m ← a[1]?
  let s ← a[2]?
  let ns ← a[3]?
  let result := Time.mk h.toNat m.toNat s.toNat ns.toNat
  if h < 0 || m < 0 || s < 0 || ns < 0 || !result.valid then none else some result
end Time

/-- A local datetime; bounds compare date first, then time, with no timezone conversion. -/
structure DateTime where
  date : Date
  time : Time := {}
  deriving Repr, BEq, Inhabited

namespace DateTime

def valid (d : DateTime) : Bool := d.date.valid && d.time.valid
instance : Ord DateTime := ⟨fun a b => (compare a.date b.date).then (compare a.time b.time)⟩
instance : LE DateTime := ⟨fun a b => compare a b ≠ .gt⟩
instance (a b : DateTime) : Decidable (a ≤ b) :=
  inferInstanceAs (Decidable (compare a b ≠ .gt))
def fields (d : DateTime) : Array Int := d.date.fields ++ d.time.fields
def fromFields (a : Array Int) : Option DateTime :=
  return ⟨← Date.fromFields a, ← Time.fromFields (a.extract 3 7)⟩
end DateTime

/-- An exact picosecond count. Negative values can express invalid bounds and are rejected. -/
structure Duration where
  picoseconds : Int
  deriving Repr, BEq, Inhabited

namespace Duration
instance : Ord Duration := ⟨fun a b => compare a.picoseconds b.picoseconds⟩
/-- Convert rational picoseconds, rounding down when finer than the representation. -/
def fromRationalPicoseconds (n : Rat) : Duration := ⟨n.num / n.den⟩

def milliseconds (n : Rat) : Duration := fromRationalPicoseconds (n * 1000000000)
def seconds (n : Rat) : Duration := fromRationalPicoseconds (n * 1000000000000)
def minutes (n : Rat) : Duration := seconds (60 * n)
def hours (n : Rat) : Duration := seconds (3600 * n)

/-- Exact conversion rejects sub-picosecond remainders instead of rounding. -/
def exactSeconds? (n : Rat) : Option Duration :=
  let ps := n * 1000000000000
  if ps.num % ps.den == 0 then some ⟨ps.num / ps.den⟩ else none
end Duration

/-- A UUID is exactly 16 bytes, retaining its wire representation. -/
structure UUID where
  bytes : Vector UInt8 16
  deriving Repr, BEq

def UUID.version (u : UUID) : UInt8 := u.bytes[6] >>> 4
def UUID.isRFCVariant (u : UUID) : Bool := u.bytes[8] &&& 0xc0 == 0x80

def UUID.toString (u : UUID) : String := Id.run do
  let digits := "0123456789abcdef".toList.toArray
  let mut chars := []
  for i in [:16] do
    if i == 4 || i == 6 || i == 8 || i == 10 then chars := '-' :: chars
    let byte := u.bytes.toArray[i]!
    chars := digits[(byte >>> 4).toNat]! :: chars
    chars := digits[(byte &&& 15).toNat]! :: chars
  return String.ofList chars.reverse
instance : ToString UUID := ⟨UUID.toString⟩

/-- An authority keeps encoded user information, host, and explicit port text separately. -/
structure URIAuth where
  userInfo : Option String := none
  host : String
  port : Option String := none
  deriving Repr, BEq, Inhabited

namespace URIAuth

private def unreserved (c : Char) : Bool :=
  (c.toNat < 128 && c.isAlphanum) || "-._~".contains c

private def subdelimiter (c : Char) : Bool := "!$&'()*+,;=".contains c
private def hex (c : Char) : Bool := "0123456789abcdefABCDEF".contains c

/-- Validate ASCII component syntax while retaining encoded bytes unchanged. -/
def validEncoded (allowed : Char → Bool) : List Char → Bool
  | '%' :: a :: b :: rest => hex a && hex b && validEncoded allowed rest
  | '%' :: _ => false
  | c :: rest => allowed c && validEncoded allowed rest
  | [] => true

def validPath (text : String) : Bool :=
  validEncoded (fun c => unreserved c || subdelimiter c || ":@/".contains c) text.toList

def validQuery (text : String) : Bool :=
  validEncoded (fun c => unreserved c || subdelimiter c || ":@/?".contains c) text.toList

private def validIPLiteral (text : String) : Bool :=
  if (Std.Net.IPv6Addr.ofString text).isSome then true
  else
    let (version, address) := text.toList.span (· != '.')
    match version, address with
    | start :: digits, '.' :: body =>
      (start == 'v' || start == 'V') && !digits.isEmpty && digits.all hex && !body.isEmpty &&
      body.all (fun c => unreserved c || subdelimiter c || c == ':')
    | _, _ => false

def toString (a : URIAuth) : String :=
  (a.userInfo.map (· ++ "@")).getD "" ++ a.host ++ (a.port.map (":" ++ ·)).getD ""
instance : ToString URIAuth := ⟨toString⟩

private def parseHostPort (value : String) : Option (String × Option String) := do
  if value.startsWith "[" then
    let (inside, suffix) := value.toList.span (· != ']')
    match suffix with
    | ']' :: rest =>
      if !validIPLiteral (String.ofList inside.tail) then none else do
        let host := String.ofList (inside ++ [']'])
        match rest with
        | [] => return (host, none)
        | ':' :: port =>
          if port.all Char.isDigit then return (host, some (String.ofList port)) else none
        | _ => none
    | _ => none
  else
    let (host, suffix) := value.toList.span (· != ':')
    if host.isEmpty || !validEncoded (fun c => unreserved c || subdelimiter c) host then none else
      match suffix with
      | [] => return (String.ofList host, none)
      | ':' :: port =>
        if port.all Char.isDigit then return (String.ofList host, some (String.ofList port))
        else none
      | _ => none

def parse (value : String) : Option URIAuth := do
  if value.toList.any Char.isWhitespace then none else do
    let parts := value.splitOn "@"
    let (userInfo, hostPort) ← match parts with
      | [hostPort] => some (none, hostPort)
      | [userInfo, hostPort] => some (some userInfo, hostPort)
      | _ => none
    if userInfo.any (fun text =>
      !validEncoded (fun c => unreserved c || subdelimiter c || c == ':') text.toList) then none
    else do
      let (host, port) ← parseHostPort hostPort
      return ⟨userInfo, host, port⟩

end URIAuth

/-- Parsed components of an absolute HTTP(S) URI. Percent escapes remain encoded. -/
structure URI where
  scheme : String
  authority : URIAuth
  path : String
  query : Option String := none
  fragment : Option String := none
  deriving Repr, BEq, Inhabited

namespace URI
private def splitOnce (delimiter : Char) (s : String) : String × Option String :=
  let (a, b) := s.toList.span (· != delimiter)
  (String.ofList a, if b.isEmpty then none else some (String.ofList b.tail))

def parse (text : String) : Option URI := do
  let (scheme, rest) := splitOnce ':' text
  if scheme.toLower != "http" && scheme.toLower != "https" then none else do
    let rest ← rest
    if !rest.startsWith "//" then none else do
      let rest := String.ofList (rest.toList.drop 2)
      let (authority, remaining) := rest.toList.span fun c => c != '/' && c != '?' && c != '#'
      let authority ← URIAuth.parse (String.ofList authority)
      let (body, fragment) := splitOnce '#' (String.ofList remaining)
      let (path, query) := splitOnce '?' body
      if !URIAuth.validPath path || query.any (fun s => !URIAuth.validQuery s) ||
          fragment.any (fun s => !URIAuth.validQuery s) then none
      else return ⟨scheme, authority, path, query, fragment⟩

def toString (u : URI) : String :=
  u.scheme ++ "://" ++ u.authority.toString ++ u.path ++
  (u.query.map ("?" ++ ·)).getD "" ++ (u.fragment.map ("#" ++ ·)).getD ""
instance : ToString URI := ⟨toString⟩
end URI

/-- Nonempty list data with an explicit head, without partial indexing. -/
structure NonEmptyList (α : Type) where
  head : α
  tail : List α
  deriving Repr, BEq

def NonEmptyList.toList (xs : NonEmptyList α) : List α := xs.head :: xs.tail

namespace Gen

def int8 : Gen Int8 := Int.toInt8 <$> int (-2 ^ 7) (2 ^ 7 - 1)
def int16 : Gen Int16 := Int.toInt16 <$> int (-2 ^ 15) (2 ^ 15 - 1)
def int32 : Gen Int32 := Int.toInt32 <$> int (-2 ^ 31) (2 ^ 31 - 1)
def int64 : Gen Int64 := Int.toInt64 <$> int (-2 ^ 63) (2 ^ 63 - 1)
def uint8 : Gen UInt8 := Nat.toUInt8 <$> nat 0 (2 ^ 8 - 1)
def uint16 : Gen UInt16 := Nat.toUInt16 <$> nat 0 (2 ^ 16 - 1)
def uint32 : Gen UInt32 := Nat.toUInt32 <$> nat 0 (2 ^ 32 - 1)
def uint64 : Gen UInt64 := Nat.toUInt64 <$> nat 0 (2 ^ 64 - 1)
def usize : Gen USize := Nat.toUSize <$> nat 0 (USize.size - 1)
def isize : Gen ISize := Int.toISize <$> int (-(USize.size / 2 : Nat)) (USize.size / 2 - 1)

def float32 (config : FloatConfig := {}) : Gen Float32 :=
  Float.toFloat32 <$> nativeValidation "float32" (Internal.float32 · config.min config.max
    config.allowNaN
    config.allowInfinity config.excludeMin config.excludeMax)

def date (lo : Date := ⟨-999999, 1, 1⟩) (hi : Date := ⟨999999, 12, 31⟩) : Gen Date := do
  if !lo.valid || !hi.valid || !(lo ≤ hi) then validation "date" "Gen.date: invalid calendar bounds"
  match Date.fromFields (← native (Internal.calendar · 0 lo.fields hi.fields)) with
  | some d => if lo ≤ d && d ≤ hi then return d else invalid "Gen.date: out of bounds"
  | none => invalid "Gen.date: invalid native date"

def time (lo : Time := .midnight) (hi : Time := .endOfDay) : Gen Time := do
  if !lo.valid || !hi.valid || !(lo ≤ hi) then validation "time" "Gen.time: invalid time bounds"
  match Time.fromFields (← native (Internal.calendar · 1 lo.fields hi.fields)) with
  | some t => if lo ≤ t && t ≤ hi then return t else invalid "Gen.time: out of bounds"
  | none => invalid "Gen.time: invalid native time"

def datetime (lo : DateTime := ⟨⟨-999999, 1, 1⟩, .midnight⟩)
    (hi : DateTime := ⟨⟨999999, 12, 31⟩, .endOfDay⟩) : Gen DateTime := do
  if !lo.valid || !hi.valid || !(lo ≤ hi) then
    validation "datetime" "Gen.datetime: invalid datetime bounds"
  match DateTime.fromFields (← native (Internal.calendar · 2 lo.fields hi.fields)) with
  | some d => if lo ≤ d && d ≤ hi then return d else invalid "Gen.datetime: out of bounds"
  | none => invalid "Gen.datetime: invalid native datetime"

/-- Exact picosecond generation, including ranges larger than UInt64. -/
def duration (lo : Duration := ⟨0⟩)
    (hi : Duration := ⟨730484633 * 86400 * 1000000000000⟩) : Gen Duration := do
  if lo.picoseconds < 0 || lo.picoseconds > hi.picoseconds then
    validation "duration" "Gen.duration: invalid nonnegative duration bounds"
  return ⟨← int lo.picoseconds hi.picoseconds⟩

def uuid (version : Option UInt8 := none) : Gen UUID := do
  if version.any (· > 15) then validation "uuid" "Gen.uuid: version exceeds 15"
  let bytes ← native (Internal.uuid · (version.getD 0) version.isSome)
  if h : bytes.data.size = 16 then return ⟨⟨bytes.data, h⟩⟩
  else invalid "Gen.uuid: native UUID does not contain 16 bytes"

def uriText : Gen String := url

def uri : Gen URI := do
  let text ← uriText
  match URI.parse text with
  | some parsed => return parsed
  | none => invalid s!"Gen.uri: invalid native URI {text}"

/-- Ordered positive weights influence choices; they do not promise uniform sampling. -/
def frequency (choices : Array (Nat × Gen α)) : Gen α := withSpan "lean.frequency" do
  if choices.isEmpty || choices.any (fun (weight, _) => weight == 0) then
    validation "frequency" "Gen.frequency: choices must be nonempty and weights positive"
  let total := choices.foldl (fun n (weight, _) => n + weight) 0
  let mut index ← nat 0 (total - 1)
  for (weight, gen) in choices do
    if index < weight then return ← gen
    index := index - weight
  invalid "Gen.frequency: invalid selected index"

def either (left : Gen α) (right : Gen β) : Gen (Sum α β) :=
  oneOf #[Sum.inl <$> left, Sum.inr <$> right]

/-- An explicit enumeration can represent any finite user-defined type. -/
class Enumeration (α : Type) where
  values : Array α

def enumBounded [Enumeration α] : Gen α :=
  if (Enumeration.values (α := α)).isEmpty then
    validation "enumBounded" "Gen.enumBounded: enumeration is empty"
  else element Enumeration.values

def enum (values : Array α) (lo hi : Nat) : Gen α := do
  if lo > hi || hi ≥ values.size then validation "enum" "Gen.enum: invalid enumeration range"
  element (values.extract lo (hi + 1))

def nonEmpty (gen : Gen α) (minSize : Nat := 1) (maxSize : Nat := 64) :
    Gen (NonEmptyList α) := do
  if minSize == 0 || minSize > maxSize || maxSize ≥ 2 ^ 64 then
    validation "nonEmpty" "Gen.nonEmpty: invalid positive size bounds"
  match ← list gen minSize maxSize with
  | head :: tail => return ⟨head, tail⟩
  | [] => invalid "Gen.nonEmpty: native empty collection"

/-- Unique collections force variable-size mode so rejecting duplicates advances the stream. -/
private def uniqueArrayCore (eq : α → α → Bool) (gen : Gen α)
    (minSize maxSize : Nat) (trim : Bool) : Gen (Array α) :=
  withSpan "lean.uniqueArrayBy" do
    if minSize > maxSize || maxSize ≥ 2 ^ 64 || minSize + 1 ≥ 2 ^ 64 then
      validation "uniqueArrayBy" "Gen.uniqueArrayBy: invalid size bounds"
    let id ← native (Internal.collection · minSize.toUInt64
      (max (minSize + 1) maxSize).toUInt64)
    ofRun fun session => do
      try
        let mut values := #[]
        for _ in [:100 * (maxSize + 1)] do
          if !(← native (Internal.more · id) session) then
            return if trim then values.take maxSize else values
          let value ← gen session
          if values.any (eq value) then native (Internal.reject · id) session
          else values := values.push value
        discard session
      finally
        native (Internal.freeCollection · id) session

/-- Generate unique values in draw order, enforcing both declared size bounds. -/
def uniqueArrayBy (eq : α → α → Bool) (gen : Gen α)
    (minSize : Nat := 0) (maxSize : Nat := 64) : Gen (Array α) :=
  uniqueArrayCore eq gen minSize maxSize true

def set [Ord α] (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) :
    Gen (Std.TreeSet α) := do
  let values ← uniqueArrayCore (fun a b => compare a b == .eq) gen minSize maxSize false
  let sorted := Std.TreeSet.ofList values.toList
  return Std.TreeSet.ofList (sorted.toList.take maxSize)

def hashSet [BEq α] [Hashable α] (gen : Gen α) (minSize : Nat := 0)
    (maxSize : Nat := 64) : Gen (Std.HashSet α) := do
  let values ← uniqueArrayCore (· == ·) gen minSize maxSize false
  let hashed := Std.HashSet.ofList values.toList
  return Std.HashSet.ofList (hashed.toList.take maxSize)

def intSet := @set Int inferInstance

/-- Key uniqueness is checked before drawing a value. Duplicate keys consume no value draw. -/
private def entriesCore (eq : α → α → Bool) (keys : Gen α) (values : Gen β)
    (minSize maxSize : Nat) (trim : Bool) : Gen (Array (α × β)) :=
  withSpan "lean.entries" do
    if minSize > maxSize || maxSize ≥ 2 ^ 64 || minSize + 1 ≥ 2 ^ 64 then
      validation "entries" "Gen.entries: invalid size bounds"
    let id ← native (Internal.collection · minSize.toUInt64
      (max (minSize + 1) maxSize).toUInt64)
    ofRun fun session => do
      try
        let mut result := #[]
        for _ in [:100 * (maxSize + 1)] do
          if !(← native (Internal.more · id) session) then
            return if trim then result.take maxSize else result
          let key ← keys session
          if result.any (fun entry => eq key entry.1) then native (Internal.reject · id) session
          else result := result.push (key, ← values session)
        discard session
      finally
        native (Internal.freeCollection · id) session

/-- Generate entries in draw order, checking uniqueness before drawing each value. -/
def entries (eq : α → α → Bool) (keys : Gen α) (values : Gen β)
    (minSize : Nat := 0) (maxSize : Nat := 64) : Gen (Array (α × β)) :=
  entriesCore eq keys values minSize maxSize true

def map [Ord α] (keys : Gen α) (values : Gen β) (minSize : Nat := 0)
    (maxSize : Nat := 64) : Gen (Std.TreeMap α β) := do
  let pairs ← entriesCore (fun a b => compare a b == .eq) keys values minSize maxSize false
  let sorted := Std.TreeMap.ofList pairs.toList
  return Std.TreeMap.ofList (sorted.toList.take maxSize)

def hashMap [BEq α] [Hashable α] (keys : Gen α) (values : Gen β) (minSize : Nat := 0)
    (maxSize : Nat := 64) : Gen (Std.HashMap α β) := do
  let pairs ← entriesCore (· == ·) keys values minSize maxSize false
  let hashed := Std.HashMap.ofList pairs.toList
  return Std.HashMap.ofList (hashed.toList.take maxSize)

def intMap (keys : Gen Int) (values : Gen β) (minSize : Nat := 0)
    (maxSize : Nat := 64) : Gen (Std.TreeMap Int β) := map keys values minSize maxSize

/-- Map and reject, precomputing finite images instead of risking a missed valid choice. -/
def mapMaybe (f : α → Option β) (gen : Gen α) (attempts : Nat := 3) : Gen β :=
  match enumerate gen with
  | some values =>
    match values.filterMap f with
    | [] => discard
    | values => element values.toArray
  | none => Gen.ofRun fun session => do
    for _ in [:attempts] do
      Gen.native (Internal.startSpan · "lean.mapMaybe") session
      let result ← (gen session).toBaseIO
      match result with
      | .ok value =>
        match f value with
        | some mapped =>
          Gen.native (Internal.stopSpan · false) session
          return mapped
        | none => Gen.native (Internal.stopSpan · true) session
      | .error error =>
        match error with
        | .recursionLeafRetry | .recursionMispriced => pure ()
        | _ => let _ ← (Internal.stopSpan session true).toBaseIO; pure ()
        throw error
    throw .discard

def filtered (predicate : α → Bool) (gen : Gen α) : Gen α :=
  mapMaybe (fun value => if predicate value then some value else none) gen

def just (gen : Gen (Option α)) : Gen α := mapMaybe id gen

end Gen
end Hegel
