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
  | recursionLeafRetry
  | recursionMispriced
  deriving Repr

/-- A generator retains a lazy finite enumeration alongside its native execution. -/
structure Gen (α : Type) where
  run : Session.type → EIO Abort α
  finiteValues : Unit → Option (List α) := fun _ ↦ none
  /-- Applicative spines execute without nested tuple wrappers. -/
  runSpine : Session.type → EIO Abort α := run
  apLeaves : Nat := 1

instance : CoeFun (Gen α) (fun _ ↦ Session.type → EIO Abort α) := ⟨Gen.run⟩

namespace Gen

def ofRun (run : Session.type → EIO Abort α) : Gen α := ⟨run, fun _ ↦ none, run, 1⟩

def enumerate (gen : Gen α) : Option (List α) := gen.finiteValues ()

def withEnumeration (values : Unit → Option (List α)) (gen : Gen α) : Gen α :=
  { gen with finiteValues := values }

private def engine (action : EIO EngineError α) : EIO Abort α :=
  action.adapt fun e ↦
    if e.code == -1 then .overrun
    else if e.code == -2 then .discard
    else .error (toString e)

/-- Restore a span on local exceptions; recursive retry signals belong to the native engine. -/
private def runInSpan (session : Session.type) (label : String) (action : EIO Abort α) :
    EIO Abort α := do
  engine (startSpan session label)
  let result ← action.toBaseIO
  match result with
  | .ok value =>
    engine (stopSpan session false)
    return value
  | .error e =>
    match e with
    | .recursionLeafRetry | .recursionMispriced => pure ()
    | _ =>
      -- Preserve the original error if the engine has already frozen the case.
      let _ ← (stopSpan session true).toBaseIO
      pure ()
    throw e

instance : Monad Gen where
  pure value := { run := fun _ ↦ pure value, finiteValues := fun _ ↦ some [value], apLeaves := 0 }
  bind gen f := ofRun fun session ↦ runInSpan session "lean.flatMap" do
    let value ← gen session
    (f value) session
  map f gen := {
    run := fun session ↦ runInSpan session "lean.mapped" (f <$> gen session)
    finiteValues := fun _ ↦ (enumerate gen).map (List.map f)
    apLeaves := gen.apLeaves
  }
  seq gf ga :=
    let spine := fun session ↦ do
      let f ← gf.runSpine session
      let value ← (ga ()) session
      return f value
    { run := fun session ↦
        if gf.apLeaves + (ga ()).apLeaves < 2 then spine session
        else runInSpan session "lean.tuple" (spine session)
      runSpine := spine
      finiteValues := fun _ ↦ do
        let fs ← enumerate gf
        let xs ← enumerate (ga ())
        return fs.flatMap fun f ↦ xs.map f
      apLeaves := gf.apLeaves + (ga ()).apLeaves }

instance : MonadExceptOf Abort Gen where
  throw e := ofRun fun _ ↦ throw e
  tryCatch gen handler := ofRun fun session ↦ try gen session catch e => handler e session

instance : MonadLiftT BaseIO Gen where
  monadLift action := ofRun fun _ ↦ action

instance : MonadFinally Gen where
  tryFinally' action finalizer := ofRun fun session ↦ do
    let result ← (action session).toBaseIO
    let after ← (finalizer result.toOption session).toBaseIO
    match result, after with
    | .error e, _ => throw e
    | .ok _, .error e => throw e
    | .ok value, .ok value' => return (value, value')

def native (f : Session.type → EIO EngineError α) : Gen α := ofRun fun s ↦ do
  if ← IO.checkCanceled then throw (.error "Property cancelled")
  engine (f s)

def invalid (message : String) : Gen α := throw (.error message)

/-- Invalid builder configuration is a counterexample with a stable generator-specific origin. -/
def validation (origin message : String) : Gen α :=
  throw (.failure ("generator/" ++ origin) message)

/-- Native invalid-argument responses are configuration failures for typed generator builders. -/
def nativeValidation (origin : String) (f : Session.type → EIO EngineError α) : Gen α :=
  ofRun fun s => do
    if ← IO.checkCanceled then throw (.error "Property cancelled")
    (f s).adapt fun e =>
    if e.code == -5 then .failure ("generator/" ++ origin) e.message
    else if e.code == -1 then .overrun
    else if e.code == -2 then .discard
    else .error (toString e)


/-- Discard the current case without reporting a counterexample. -/
def assume (condition : Bool) : Gen Unit :=
  unless condition do throw .discard

def discard : Gen α := throw .discard

/-- Group draws into a unit that the engine can shrink together. -/
def withSpan (label : String) (gen : Gen α) : Gen α :=
  let run := fun session ↦ runInSpan session label (gen session)
  { gen with run, runSpine := run }

/-- Delay construction, useful on recursive edges in a strict language. -/
def defer (f : Unit → Gen α) : Gen α := ofRun fun s ↦ f () s

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
def element (values : Array α) : Gen α :=
  withEnumeration (fun _ ↦ if values.isEmpty then none else some values.toList) <|
  withSpan "lean.element" do
  if h : 0 < values.size then
    let i ← fin values.size h
    return values[i]
  else invalid "Gen.element requires at least one value"

def oneOf (choices : Array (Gen α)) : Gen α :=
  withEnumeration (fun _ ↦ do
    let values ← choices.toList.mapM enumerate
    return values.flatten) <| withSpan "lean.oneOf" do
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
    let result ← ofRun fun session ↦ (gen session).toBaseIO
    let a ← match result with
      | .ok value => pure value
      | .error e =>
        match e with
        | .recursionLeafRetry | .recursionMispriced => pure ()
        | _ =>
          let _ ← ofRun fun session ↦ (stopSpan session true).toBaseIO
          pure ()
        throw e
    let accepted := predicate a
    native (stopSpan · (!accepted))
    if accepted then return a
  discard

/-- Engine-managed lengths retain Hegel's collection shrinking behavior. -/
def array (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) : Gen (Array α) :=
  withSpan "lean.array" do
    let (lo, hi) ← sizes minSize maxSize
    let id ← native (collection · lo hi)
    ofRun fun session => do
      try
        let mut values := #[]
        for _ in [:maxSize + 1] do
          if !(← native (more · id) session) then return values
          values := values.push (← withSpan "lean.array.element" gen session)
        invalid "Engine exceeded the requested collection size" session
      finally native (freeCollection · id) session

def list (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) : Gen (List α) :=
  Array.toList <$> array gen minSize maxSize

def vector (gen : Gen α) (n : Nat) : Gen (Vector α n) := do
  let values ← array gen n n
  if h : values.size = n then return ⟨values, h⟩
  else invalid "Engine returned the wrong vector length"

/-- Unique values use Lean equality; rejected duplicates do not consume a collection slot. -/
def uniqueArray [BEq α] (gen : Gen α) (minSize : Nat := 0) (maxSize : Nat := 64) :
    Gen (Array α) := withSpan "lean.uniqueArray" do
  let (lo, hi) ← sizes minSize (max maxSize (minSize + 1))
  if minSize > maxSize then invalid "Minimum size exceeds maximum size"
  let id ← native (collection · lo hi)
  ofRun fun session => do
    try
      let mut values := #[]
      for _ in [:100 * (maxSize + 2)] do
        if !(← native (more · id) session) then return values.extract 0 maxSize
        let value ← withSpan "lean.uniqueArray.element" gen session
        if values.contains value then native (reject · id) session
        else values := values.push value
      discard session
    finally native (freeCollection · id) session

/-- Build a recursive generator with an explicit maximum depth. -/
def recursive (depth : Nat) (leaf : Gen α) (branch : Gen α → Gen α) : Gen α :=
  match depth with
  | 0 => leaf
  | n + 1 => oneOf #[leaf, defer fun _ => branch (recursive n leaf branch)]

end Gen
end Hegel
