import Hegel.Gen.Standard

namespace Hegel

/-- A default generator parameterized by a size budget. Instances should document
how they use the budget; it is not a bound on the number of engine evaluations. -/
class Arbitrary (α : Type) where
  arbitrary : Nat → Gen α

/-- Generate using the selected instance and an explicit, reproducible size budget. -/
def arbitrary [Arbitrary α] (size : Nat := 30) : Gen α := Arbitrary.arbitrary size

namespace Gen

/-- Retain a decidable predicate as a kernel-checked proof in each generated value.
Rejected candidates remain rejections, including during shrinking and replay. -/
def subtype (predicate : α → Prop) [DecidablePred predicate] (gen : Gen α)
    (attempts : Nat := 3) : Gen {x : α // predicate x} :=
  mapMaybe (fun x => if h : predicate x then some ⟨x, h⟩ else none) gen attempts

/-- Draw directly from an inclusive natural-number interval and check its evidence. -/
def natRange (lo hi : Nat) : Gen {n : Nat // lo ≤ n ∧ n ≤ hi} := do
  let n ← nat lo hi
  if h : lo ≤ n ∧ n ≤ hi then return ⟨n, h⟩
  else invalid "Engine returned a natural number outside the requested interval"

/-- Draw directly from an inclusive integer interval and check its evidence. -/
def intRange (lo hi : Int) : Gen {n : Int // lo ≤ n ∧ n ≤ hi} := do
  let n ← int lo hi
  if h : lo ≤ n ∧ n ≤ hi then return ⟨n, h⟩
  else invalid "Engine returned an integer outside the requested interval"

/-- Generate dependent data after its index; neither the index nor its evidence
is reconstructed with unchecked casts. -/
def sigma (indices : Gen α) (values : (a : α) → Gen (β a)) : Gen (Sigma β) := do
  let a ← indices
  return ⟨a, ← values a⟩

/-- Bounded recursion for derived generators. Recursive requests are clamped below
the current budget. Delayed edges avoid eagerly expanding recursive trees. -/
def sizedFix (body : (Nat → Gen α) → Nat → Gen α) (size : Nat) : Gen α :=
  match size with
  | 0 => body (fun _ => discard) 0
  | n + 1 => body (fun requested => defer fun _ => sizedFix body (min requested n)) (n + 1)
termination_by size
decreasing_by exact Nat.lt_succ_of_le (Nat.min_le_right _ _)

/-- Split a collection's budget among its elements after choosing the length. -/
def sizedArray (elements : Nat → Gen α) (size : Nat) : Gen (Array α) := do
  let length ← nat 0 size
  array (elements (size / max length 1)) length length

end Gen

instance : Arbitrary Unit := ⟨fun _ => pure ()⟩
instance : Arbitrary Empty := ⟨fun _ => Gen.discard⟩
instance : Arbitrary Bool := ⟨fun _ => Gen.bool⟩
instance : Arbitrary Nat := ⟨fun size => Gen.nat 0 size⟩
instance : Arbitrary Int := ⟨fun size => Gen.int (-Int.ofNat size) size⟩
instance : Arbitrary UInt8 := ⟨fun _ => Gen.uint8⟩
instance : Arbitrary UInt16 := ⟨fun _ => Gen.uint16⟩
instance : Arbitrary UInt32 := ⟨fun _ => Gen.uint32⟩
instance : Arbitrary UInt64 := ⟨fun _ => Gen.uint64⟩
instance : Arbitrary Int8 := ⟨fun _ => Gen.int8⟩
instance : Arbitrary Int16 := ⟨fun _ => Gen.int16⟩
instance : Arbitrary Int32 := ⟨fun _ => Gen.int32⟩
instance : Arbitrary Int64 := ⟨fun _ => Gen.int64⟩
instance : Arbitrary Float := ⟨fun _ => Gen.float⟩
instance : Arbitrary Float32 := ⟨fun _ => Gen.float32⟩
instance : Arbitrary Char := ⟨fun _ => Gen.char⟩
instance : Arbitrary String := ⟨fun size => Gen.text { maxSize := size }⟩
instance : Arbitrary ByteArray := ⟨fun size => Gen.bytes 0 size⟩
instance [Arbitrary α] : Arbitrary (Option α) :=
  ⟨fun size => Gen.option (arbitrary size)⟩
instance [Arbitrary α] : Arbitrary (List α) :=
  ⟨fun size => Array.toList <$> Gen.sizedArray Arbitrary.arbitrary size⟩
instance [Arbitrary α] : Arbitrary (Array α) :=
  ⟨fun size => Gen.sizedArray Arbitrary.arbitrary size⟩
instance [Arbitrary α] [Arbitrary β] : Arbitrary (α × β) :=
  ⟨fun size => Prod.mk <$> arbitrary (size / 2) <*> arbitrary (size / 2)⟩
instance [Arbitrary α] [Arbitrary β] : Arbitrary (Sum α β) :=
  ⟨fun size => Gen.oneOf #[Sum.inl <$> arbitrary size, Sum.inr <$> arbitrary size]⟩
instance (n : Nat) : Arbitrary (Fin n) :=
  ⟨fun _ => if h : 0 < n then Gen.fin n h else Gen.discard⟩
instance [Arbitrary α] (n : Nat) : Arbitrary (Vector α n) :=
  ⟨fun size => Gen.vector (arbitrary (size / max n 1)) n⟩
instance [Arbitrary α] (predicate : α → Prop) [DecidablePred predicate] :
    Arbitrary {x : α // predicate x} :=
  ⟨fun size => Gen.subtype predicate (arbitrary size)⟩
instance {α : Type} {β : α → Type} [Arbitrary α] [∀ a, Arbitrary (β a)] : Arbitrary (Sigma β) :=
  ⟨fun size => Gen.sigma (arbitrary (size / 2)) (fun _ => arbitrary (size / 2))⟩

end Hegel
