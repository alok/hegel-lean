import Hegel.Internal.Raw

/-! Composable generators. Hegel records and shrinks every primitive draw. -/
namespace Hegel
open Internal

/-- Test-case control flow is distinct from a counterexample and an engine error. -/
inductive Abort where
  | discard
  | overrun
  | failure (origin message : String)
  | error (message : String)
  deriving Repr

/-- A generator may depend on earlier draws and can reject the current case. -/
abbrev Gen := ReaderT Session.type (EIO Abort)

namespace Gen

def native (f : Session.type → EIO EngineError α) : Gen α := fun s =>
  (f s).adapt fun e =>
    if e.code == -1 then .overrun
    else if e.code == -2 then .discard
    else .error (toString e)

def invalid (message : String) : Gen α := throw (.error message)

/-- Discard the current case without reporting a counterexample. -/
def assume (condition : Bool) : Gen Unit :=
  unless condition do throw .discard

def discard : Gen α := throw .discard

/-- Group draws into a unit that the engine can shrink together. -/
def withSpan (label : String) (gen : Gen α) : Gen α := do
  native (startSpan · label)
  let value ← gen
  native (stopSpan · false)
  return value

/-- Delay construction, useful on recursive edges in a strict language. -/
def defer (f : Unit → Gen α) : Gen α := fun s => f () s

def bool (probability : Float := 0.5) : Gen Bool := native (boolean · probability)

/-- Encode a signed integer in two's-complement little-endian bytes. -/
def encodeInt (n : Int) : ByteArray := Id.run do
  let mut value := n
  let mut bytes := ByteArray.empty
  for _ in [:n.natAbs.log2 / 8 + 2] do
    bytes := bytes.push (value % 256).toNat.toUInt8
    value := value / 256
  return bytes

/-- Decode two's-complement bytes, including engine sign extension. -/
def decodeInt (bytes : ByteArray) : Int := Id.run do
  let mut value : Nat := 0
  for b in bytes.data.reverse do
    value := value * 256 + b.toNat
  if bytes.size > 0 && bytes[bytes.size - 1]! ≥ 128 then
    return (value : Int) - (256 : Int) ^ bytes.size
  return value

/-- Inclusive arbitrary-precision integer bounds; never truncates to a machine word. -/
def int (min max : Int) : Gen Int := do
  if min > max then invalid "Gen.int: minimum exceeds maximum"
  else if min ≥ -9223372036854775808 && max ≤ 9223372036854775807 then
    native (integer · min.toInt64 max.toInt64)
  else
    return decodeInt (← native (integerBig · (encodeInt min) (encodeInt max)))

def nat (min max : Nat) : Gen Nat := Int.toNat <$> int min max

/-- A generated finite index carries a kernel-checked bound proof. -/
def fin (n : Nat) (_positive : 0 < n) : Gen (Fin n) := do
  let i ← nat 0 (n - 1)
  if h : i < n then return ⟨i, h⟩
  else invalid s!"Engine returned an out-of-range index {i} for Fin {n}"

structure FloatConfig where
  min : Float := -1 / 0
  max : Float := 1 / 0
  allowNaN : Bool := true
  allowInfinity : Bool := true
  excludeMin : Bool := false
  excludeMax : Bool := false

def float (config : FloatConfig := {}) : Gen Float :=
  native (Internal.float · config.min config.max config.allowNaN config.allowInfinity
    config.excludeMin config.excludeMax)

private def sizes (min max : Nat) : Gen (UInt64 × UInt64) := do
  if min > max then invalid "Minimum size exceeds maximum size"
  else if max ≥ 2 ^ 64 then invalid "Collection size exceeds the engine's UInt64 range"
  else return (min.toUInt64, max.toUInt64)

def bytes (minSize : Nat := 0) (maxSize : Nat := 64) : Gen ByteArray := do
  let (lo, hi) ← sizes minSize maxSize
  native (Internal.bytes · lo hi)

structure TextConfig where
  minSize : Nat := 0
  maxSize : Nat := 64
  minCodepoint : UInt32 := 0
  maxCodepoint : UInt32 := 0x10ffff
  codec : String := "utf-8"

/-- Unicode scalar text. Embedded NULs are preserved; surrogate codepoints are excluded. -/
def text (config : TextConfig := {}) : Gen String := do
  let (lo, hi) ← sizes config.minSize config.maxSize
  native (Internal.text · lo hi config.minCodepoint config.maxCodepoint config.codec)

def char : Gen Char := do
  let s ← text { minSize := 1, maxSize := 1 }
  match s.toList with
  | [c] => return c
  | _ => invalid "Engine returned a non-singleton character"

def regex (pattern : String) (fullMatch : Bool := true) : Gen String :=
  native (Internal.string · 0 pattern fullMatch 0)
def email : Gen String := native (Internal.string · 1 "" false 0)
def url : Gen String := native (Internal.string · 2 "" false 0)
def domain (maxLength : UInt64 := 255) : Gen String :=
  native (Internal.string · 3 "" false maxLength)

/-- Choose from a finite array. An empty array is a configuration error. -/
def element (values : Array α) : Gen α := withSpan "lean.element" do
  if h : 0 < values.size then
    let i ← fin values.size h
    return values[i]
  else invalid "Gen.element requires at least one value"

def oneOf (choices : Array (Gen α)) : Gen α := withSpan "lean.oneOf" do
  let selected ← element choices
  selected

def option (gen : Gen α) : Gen (Option α) :=
  oneOf #[pure none, some <$> gen]

def pair (a : Gen α) (b : Gen β) : Gen (α × β) := withSpan "lean.pair" do
  return (← a, ← b)

/-- Bounded rejection sampling; rejected attempts are marked as discarded spans. -/
def filter (predicate : α → Bool) (gen : Gen α) (attempts : Nat := 3) : Gen α := do
  for _ in [:attempts] do
    native (startSpan · "lean.filter")
    let a ← gen
    let accepted := predicate a
    native (stopSpan · (!accepted))
    if accepted then return a
  discard

/-- Engine-managed lengths retain Hegel's collection shrinking behavior. -/
def array (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) : Gen (Array α) :=
  withSpan "lean.array" do
    let (lo, hi) ← sizes minSize maxSize
    let id ← native (collection · lo hi)
    let mut values := #[]
    for _ in [:maxSize + 1] do
      if !(← native (more · id)) then
        native (freeCollection · id)
        return values
      values := values.push (← withSpan "lean.array.element" gen)
    invalid "Engine exceeded the requested collection size"

def list (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) : Gen (List α) :=
  Array.toList <$> array gen minSize maxSize

def vector (gen : Gen α) (n : Nat) : Gen (Vector α n) := do
  let values ← array gen n n
  if h : values.size = n then return ⟨values, h⟩
  else invalid "Engine returned the wrong vector length"

/-- Unique values use Lean equality; rejected duplicates do not consume a collection slot. -/
def uniqueArray [BEq α] (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) :
    Gen (Array α) := withSpan "lean.uniqueArray" do
  let (lo, hi) ← sizes minSize maxSize
  let id ← native (collection · lo hi)
  let mut values := #[]
  -- Hegel has its own rejection budget; this additional bound keeps this frontend total.
  for _ in [:100 * (maxSize + 1)] do
    if !(← native (more · id)) then
      native (freeCollection · id)
      return values
    let value ← withSpan "lean.uniqueArray.element" gen
    if values.contains value then native (reject · id)
    else values := values.push value
  discard

/-- Build a recursive generator with an explicit maximum depth. -/
def recursive (depth : Nat) (leaf : Gen α) (branch : Gen α → Gen α) : Gen α :=
  match depth with
  | 0 => leaf
  | n + 1 => oneOf #[leaf, defer fun _ => branch (recursive n leaf branch)]

end Gen
end Hegel
