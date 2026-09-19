import Hegel.Gen.Standard

/-! Typed configuration builders. Use `Gen.build` after applying supported modifiers. -/
namespace Hegel.Gen

class Build (builder : Type) (α : outParam Type) where
  build : builder → Gen α
export Build (build)

class HasMin (builder : Type) (α : outParam Type) where
  min : α → builder → builder
class HasMax (builder : Type) (α : outParam Type) where
  max : α → builder → builder
class HasSize (builder : Type) where
  minSize : Int → builder → builder
  maxSize : Int → builder → builder
class HasYear (builder : Type) where
  minYear : Int → builder → builder
  maxYear : Int → builder → builder
class HasAlphabet (builder : Type) where
  alphabet : Alphabet → builder → builder
export HasMin (min)
export HasMax (max)
export HasSize (minSize maxSize)
export HasYear (minYear maxYear)
export HasAlphabet (alphabet)

/-- Inclusive bounds with a type-specific native draw operation. -/
structure BoundedBuilder (α : Type) where
  lower : α
  upper : α
  generate : α → α → Gen α

instance : Build (BoundedBuilder α) α := ⟨fun b => b.generate b.lower b.upper⟩
instance : HasMin (BoundedBuilder α) α := ⟨fun value b => { b with lower := value }⟩
instance : HasMax (BoundedBuilder α) α := ⟨fun value b => { b with upper := value }⟩

/-- A machine integer type can supply its exact mathematical range and conversions. -/
class Integral (α : Type) where
  lower : Int
  upper : Int
  toInt : α → Int
  fromInt : Int → α

private def integralBuilder [Integral α] : BoundedBuilder α :=
  let g lo hi := do
    if Integral.toInt lo > Integral.toInt hi then
      validation "integral" "Gen.build: minimum exceeds maximum"
    Integral.fromInt <$> Gen.int (Integral.toInt lo) (Integral.toInt hi)
  ⟨Integral.fromInt (Integral.lower (α := α)), Integral.fromInt (Integral.upper (α := α)), g⟩

instance : Integral Int8 := ⟨-2 ^ 7, 2 ^ 7 - 1, Int8.toInt, Int.toInt8⟩
instance : Integral Int16 := ⟨-2 ^ 15, 2 ^ 15 - 1, Int16.toInt, Int.toInt16⟩
instance : Integral Int32 := ⟨-2 ^ 31, 2 ^ 31 - 1, Int32.toInt, Int.toInt32⟩
instance : Integral Int64 := ⟨-2 ^ 63, 2 ^ 63 - 1, Int64.toInt, Int.toInt64⟩
instance : Integral UInt8 := ⟨0, 2 ^ 8 - 1, (·.toNat), (·.toNat.toUInt8)⟩
instance : Integral UInt16 := ⟨0, 2 ^ 16 - 1, (·.toNat), (·.toNat.toUInt16)⟩
instance : Integral UInt32 := ⟨0, 2 ^ 32 - 1, (·.toNat), (·.toNat.toUInt32)⟩
instance : Integral UInt64 := ⟨0, 2 ^ 64 - 1, (·.toNat), (·.toNat.toUInt64)⟩
instance : Integral USize := ⟨0, USize.size - 1, (·.toNat), (·.toNat.toUSize)⟩
instance : Integral ISize :=
  ⟨-(USize.size / 2 : Nat), USize.size / 2 - 1, ISize.toInt, Int.toISize⟩

structure BoolBuilder where
  probability : Float := 0.5
instance : Build BoolBuilder Bool :=
  ⟨fun b => nativeValidation "bool" (Internal.boolean · b.probability)⟩
def weighted (p : Float) (b : BoolBuilder) : BoolBuilder := { b with probability := p }

/-- Bounds implicitly exclude NaN; two explicit bounds also exclude infinity. -/
structure FloatBuilder (α : Type) where
  lower : Option α := none
  upper : Option α := none
  exclusiveLower : Bool := false
  exclusiveUpper : Bool := false
  allowNaN : Bool := true
  allowInfinity : Bool := true
instance : HasMin (FloatBuilder α) α := ⟨fun value b => { b with lower := some value }⟩
instance : HasMax (FloatBuilder α) α := ⟨fun value b => { b with upper := some value }⟩
def exclusiveMin (b : FloatBuilder α) : FloatBuilder α := { b with exclusiveLower := true }
def exclusiveMax (b : FloatBuilder α) : FloatBuilder α := { b with exclusiveUpper := true }
def disallowNaN (b : FloatBuilder α) : FloatBuilder α := { b with allowNaN := false }
def disallowInfinity (b : FloatBuilder α) : FloatBuilder α := { b with allowInfinity := false }
private def floatConfig (convert : α → Float) (b : FloatBuilder α) : FloatConfig :=
  { min := (b.lower.map convert).getD (-1 / 0)
    max := (b.upper.map convert).getD (1 / 0)
    excludeMin := b.exclusiveLower
    excludeMax := b.exclusiveUpper
    allowNaN := b.allowNaN && !b.lower.isSome && !b.upper.isSome
    allowInfinity := b.allowInfinity && !(b.lower.isSome && b.upper.isSome) }
instance : Build (FloatBuilder Float) Float := ⟨fun b =>
  let c := floatConfig id b
  nativeValidation "float" (Internal.float · c.min c.max c.allowNaN c.allowInfinity
    c.excludeMin c.excludeMax)⟩
instance : Build (FloatBuilder Float32) Float32 :=
  ⟨fun b => Gen.float32 (floatConfig Float32.toFloat b)⟩

/-- Lengths are validated before converting to the engine's UInt64 range. -/
structure SizedBuilder (α : Type) where
  lower : Int := 0
  upper : Option Int := none
  generate : Nat → Nat → Gen α
instance : HasSize (SizedBuilder α) where
  minSize value b := { b with lower := value }
  maxSize value b := { b with upper := some value }
instance : Build (SizedBuilder α) α where
  build b := do
    let hi := b.upper.getD (2 ^ 64 - 1)
    if b.lower < 0 || hi < b.lower || hi ≥ 2 ^ 64 then
      validation "build" "Gen.build: invalid collection size bounds"
    b.generate b.lower.toNat hi.toNat

structure TextBuilder where
  lower : Int := 0
  upper : Option Int := none
  chars : Alphabet := {}
instance : HasSize TextBuilder where
  minSize value b := { b with lower := value }
  maxSize value b := { b with upper := some value }
instance : HasAlphabet TextBuilder := ⟨fun chars b => { b with chars }⟩
instance : Build TextBuilder String where
  build b := build (SizedBuilder.mk b.lower b.upper (fun lo hi => b.chars.text lo hi))

abbrev CharBuilder := Alphabet
instance : Build CharBuilder Char := ⟨Alphabet.char⟩
def codec (value : Codec) (b : CharBuilder) : CharBuilder := { b with codec := value }
def minCodepoint (value : Nat) (b : CharBuilder) : CharBuilder := { b with minCodepoint := value }
def maxCodepoint (value : Nat) (b : CharBuilder) : CharBuilder := { b with maxCodepoint := value }
def categories (value : Array GeneralCategory) (b : CharBuilder) : CharBuilder :=
  { b with categories := some value }
def excludeCategories (value : Array GeneralCategory) (b : CharBuilder) : CharBuilder :=
  { b with excludeCategories := value }
def includeCharacters (value : String) (b : CharBuilder) : CharBuilder :=
  { b with includeCharacters := value }
def excludeCharacters (value : String) (b : CharBuilder) : CharBuilder :=
  { b with excludeCharacters := value }

structure RegexBuilder where
  pattern : String
  whole : Bool := false
  chars : Option Alphabet := none
instance : HasAlphabet RegexBuilder := ⟨fun chars b => { b with chars := some chars }⟩
instance : Build RegexBuilder String where
  build b := match b.chars with
    | some chars => chars.regex b.pattern b.whole
    | none => nativeValidation "regex" (Internal.string · 0 b.pattern b.whole 0)
def fullMatch (b : RegexBuilder) : RegexBuilder := { b with whole := true }

structure UuidBuilder where
  selectedVersion : Option UInt8 := none
instance : Build UuidBuilder UUID := ⟨fun b => Gen.uuid b.selectedVersion⟩
def version (value : UInt8) (b : UuidBuilder) : UuidBuilder :=
  { b with selectedVersion := some value }

structure DomainBuilder where
  limit : UInt64 := 255
instance : Build DomainBuilder String :=
  ⟨fun b => nativeValidation "domain" (Internal.string · 3 "" false b.limit)⟩
def maxLength (value : UInt64) (b : DomainBuilder) : DomainBuilder := { b with limit := value }

instance : HasYear (BoundedBuilder Date) where
  minYear y b := { b with lower := ⟨y, 1, 1⟩ }
  maxYear y b := { b with upper := ⟨y, 12, 31⟩ }
instance : HasYear (BoundedBuilder DateTime) where
  minYear y b := { b with lower := ⟨⟨y, 1, 1⟩, .midnight⟩ }
  maxYear y b := { b with upper := ⟨⟨y, 12, 31⟩, .endOfDay⟩ }
def onDay (day : Date) (b : BoundedBuilder DateTime) : BoundedBuilder DateTime :=
  { b with lower := ⟨day, .midnight⟩, upper := ⟨day, .endOfDay⟩ }

structure ListBuilder (α : Type) where
  elements : Gen α
  lower : Int := 0
  upper : Option Int := none
  equality : Option (α → α → Bool) := none
instance : HasSize (ListBuilder α) where
  minSize value b := { b with lower := value }
  maxSize value b := { b with upper := some value }
instance : Build (ListBuilder α) (List α) where
  build b := build (SizedBuilder.mk b.lower b.upper fun lo hi =>
    match b.equality with
    | some eq => Array.toList <$> Gen.uniqueArrayBy eq b.elements lo hi
    | none => Gen.list b.elements lo hi)
def unique (eq : α → α → Bool) (b : ListBuilder α) : ListBuilder α :=
  { b with equality := some eq }

/- Builder constructors keep the direct Gen API source-compatible. -/
namespace Builder

def integral [Integral α] : BoundedBuilder α := integralBuilder
def int8 : BoundedBuilder Int8 := integral
def int16 : BoundedBuilder Int16 := integral
def int32 : BoundedBuilder Int32 := integral
def int64 : BoundedBuilder Int64 := integral
def uint8 : BoundedBuilder UInt8 := integral
def uint16 : BoundedBuilder UInt16 := integral
def uint32 : BoundedBuilder UInt32 := integral
def uint64 : BoundedBuilder UInt64 := integral
def usize : BoundedBuilder USize := integral
def isize : BoundedBuilder ISize := integral
/-- Arbitrary precision integers require explicit finite bounds. -/
def integer (lo hi : Int) : BoundedBuilder Int := ⟨lo, hi, fun lo hi => do
  if lo > hi then validation "integer" "Gen.Builder.integer: minimum exceeds maximum"
  Gen.int lo hi⟩
def bool : BoolBuilder := {}
def float : FloatBuilder Float := {}
def float32 : FloatBuilder Float32 := {}
def binary : SizedBuilder ByteArray := ⟨0, none, (fun lo hi => Gen.bytes lo hi)⟩
def text : TextBuilder := {}
def char : CharBuilder := {}
def regex (pattern : String) : RegexBuilder := ⟨pattern, false, none⟩
def uuid : UuidBuilder := {}
def domain : DomainBuilder := {}
def email : Gen String := Gen.email
def uri : Gen URI := Gen.uri
def uriText : Gen String := Gen.uriText
def date : BoundedBuilder Date := ⟨⟨-999999, 1, 1⟩, ⟨999999, 12, 31⟩, (fun lo hi => Gen.date lo hi)⟩
def time : BoundedBuilder Time := ⟨.midnight, .endOfDay, (fun lo hi => Gen.time lo hi)⟩
def datetime : BoundedBuilder DateTime :=
  ⟨⟨⟨-999999, 1, 1⟩, .midnight⟩, ⟨⟨999999, 12, 31⟩, .endOfDay⟩, (fun lo hi => Gen.datetime lo hi)⟩
def duration : BoundedBuilder Duration :=
  ⟨⟨0⟩, ⟨730484633 * 86400 * 1000000000000⟩, (fun lo hi => Gen.duration lo hi)⟩
def list (elements : Gen α) : ListBuilder α := ⟨elements, 0, none, none⟩
def nonEmpty (elements : Gen α) : SizedBuilder (NonEmptyList α) :=
  ⟨1, none, (fun lo hi => Gen.nonEmpty elements lo hi)⟩
def set [Ord α] (elements : Gen α) : SizedBuilder (Std.TreeSet α) :=
  ⟨0, none, (fun lo hi => Gen.set elements lo hi)⟩
def hashSet [BEq α] [Hashable α] (elements : Gen α) : SizedBuilder (Std.HashSet α) :=
  ⟨0, none, (fun lo hi => Gen.hashSet elements lo hi)⟩
def intSet (elements : Gen Int) : SizedBuilder (Std.TreeSet Int) := set elements
def map [Ord α] (keys : Gen α) (values : Gen β) : SizedBuilder (Std.TreeMap α β) :=
  ⟨0, none, (fun lo hi => Gen.map keys values lo hi)⟩
def hashMap [BEq α] [Hashable α] (keys : Gen α) (values : Gen β) :
    SizedBuilder (Std.HashMap α β) := ⟨0, none, (fun lo hi => Gen.hashMap keys values lo hi)⟩
def intMap (keys : Gen Int) (values : Gen β) : SizedBuilder (Std.TreeMap Int β) :=
  map keys values

end Builder

instance : Build (Gen α) α := ⟨id⟩

end Hegel.Gen
