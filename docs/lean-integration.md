# Lean integration in v2

V2 adds typeclass-driven generation, automatic deriving, proof-carrying values, and
compiled test discovery. The v1 API and pinned engine remain available. The stable
v1 baseline is [v1.0.0](https://github.com/alok/hegel-lean/releases/tag/v1.0.0).

## Generate from types

```lean
import Hegel
open Hegel

structure IndexedValue where
  bound : Nat
  index : Fin (bound + 1)
  valid : index.val ≤ bound
  deriving Repr, Arbitrary

def indexedValues : Gen IndexedValue := arbitrary 20
```

`Arbitrary α` supplies `arbitrary : Nat → Gen α`. The public `Hegel.arbitrary`
helper defaults to size 30. A size is fixed for the campaign and replay, rather
than increasing with the number of examples. Changing the size or selected
instance can invalidate a saved replay, as can any change to generator structure.

| Type | Meaning of size |
| --- | --- |
| `Nat`, `Int` | Inclusive `0..size` or `-size..size` |
| `String`, `ByteArray` | Maximum character or byte length |
| `List α`, `Array α` | Maximum length; budget divided by the chosen length for elements |
| `Option`, sums | Passed to the selected component |
| Products, dependent pairs | Half the budget for each component |
| `Vector α n` | Length is exactly `n`; budget divided among elements |
| `Fin n` | Range is exactly `0..n-1`; `Fin 0` rejects |
| Booleans, characters, fixed-width integers, floats | Use their ordinary generators; size is ignored |
| Derived types | Budget divided among data fields; every recursive call decreases it |

Floats retain the ordinary generator's NaN/infinity behavior. `Empty` rejects.
Instances can be replaced locally or defined explicitly to choose distributions:

```lean
def largeNaturals : Property Unit :=
  letI : Arbitrary Nat := ⟨fun size => Gen.nat 1000 (1000 + size)⟩
  do
    let n ← forAll! (arbitrary (α := Nat) 50)
    assertProp! (1000 ≤ n ∧ n ≤ 1050)
```

## Derivation and dependent data

`deriving Arbitrary` supports enums, structures with type/value parameters,
ordinary recursive inductives, and nested recursion such as `List Tree`.
Constructor fields are generated in declaration order, so later types may depend
on earlier values. Proof fields require executable `Decidable` instances; a
false predicate rejects the candidate. The generated code is checked by Lean.
There are no inserted axioms, unchecked casts, or `sorry` terms.

```lean
inductive Tree where
  | leaf (value : Nat)
  | node (left right : Tree)
  deriving Repr, Arbitrary

def trees : Gen Tree := arbitrary 5
```

Recursive calls use a terminating, delayed size recursion, with the decrease
proved to Lean's kernel. Requested child budgets are clamped below the parent's
budget, including recursive occurrences inside containers. At size
zero, constructors with a direct recursive field are omitted. Nested containers
can still produce terminal values, such as an empty list of children. A type
with no inhabitants within the budget rejects. Distributing the budget keeps
ordinary branching structures small at the default size. Size is an upper bound
on recursive depth, not an exact node count or a universal allocation bound;
custom instances and fixed dependent lengths can require additional work. Use an
explicit `Gen.Builder.recursive` generator when a shared native leaf budget is
needed.

Derivation deliberately rejects indexed and mutually recursive inductives,
type-valued constructor fields, and fields without usable generator/decidability
instances. Supply explicit instances for those types. Runtime generators operate
on `Type` (universe zero), matching the existing `Gen` API. This is not a universal
generator for arbitrary Lean types or proofs.

## Values with evidence

```lean
def evenNumbers : Gen {n : Nat // n % 2 = 0} :=
  Gen.subtype (fun n => n % 2 = 0) (Gen.nat 0 100)

def boundedNumbers : Gen {n : Nat // 1000 ≤ n ∧ n ≤ 2000} :=
  Gen.natRange 1000 2000

def dependentVectors : Gen ((n : Nat) × Vector Bool n) :=
  Gen.sigma (Gen.nat 0 20) (fun n => Gen.vector Gen.bool n)
```

`Gen.subtype` retains the proof from a decidable check. It filters known finite
enumerations before drawing; otherwise it tries three candidates by default.
An impossible predicate rejects, and a campaign with no valid inputs cannot pass.
For sparse predicates, construct valid data directly rather than relying on many
rejections. `Gen.natRange`, `Gen.intRange`, `Gen.fin`, and `Gen.vector` generate
within the requested bounds and check the evidence. `Gen.sigma` pairs an index
with a value whose type depends on it. Subtypes and dependent pairs also have
`Arbitrary` instances when their components do.

Shrinking reruns these constructors and checks. Thus every returned subtype or
dependent value still has its evidence after shrinking or replay. A finite test
campaign does not prove a universally quantified theorem. Lean checks the proof
fields; the native engine and bridge retain the trust boundary described in the
README.

## Test functions and register suites

```lean
@[hegel_test] def reverseTwice : Property Unit :=
  property% (fun xs : List Nat => xs.reverse.reverse == xs)

@[hegel_test] def dependentIndex : Property Unit :=
  property% (size := 12) (fun (n : Nat) (i : Fin (n + 1)) => decide (i.val ≤ n))
```

`property%` uses `Testable` to generate each argument, requiring `Arbitrary` and
`Repr` for its type. Functions can return a `Bool`, another function, or a
`Property Unit`. Use `decide` for propositions, or call `Property.forAllProp` with
an explicit generator and decidable predicate. Every generated argument is
recorded, and Boolean failures receive a stable module/line/column origin from
the `property%` call. Effects in a property can run again during shrinking.

The `@[hegel_test]` attribute accepts closed definitions of `Property Unit` or
`Test`. A `Test` retains its explicit name and settings; a bare property gets its
fully qualified declaration name and default settings. Invalid declarations and
axioms are rejected at compile time.

In a compiled executable that imports your test modules:

```lean
def main : IO UInt32 := runTests hegel_suite%
```

`hegel_suite%` collects public registered tests from imported modules and tests
already declared in the current module. It orders them by fully qualified
declaration name. It is an elaboration-time snapshot: import/declare every test
before constructing it. Private imported definitions are not exported. To
restrict the suite, use `hegel_suite% in MyProject.Tests` with a fully qualified
namespace. An empty selection is a compile error.

In your `lakefile.lean`, register the executable as the test driver:

```lean
@[test_driver]
lean_exe tests where
  root := `Tests.Main
```

Then `lake test` builds and runs it, returning failure for counterexamples,
rejection exhaustion, engine errors, or flaky results. It runs a native
executable, so it inherits Hegel's link dependencies. This does not require or
install an editor `#eval` engine plugin.

## Validation

`lake exe hegel_lean_examples` runs the complete example, and `lake test` includes
`Tests.LeanFeatures`. Its cases cover size-zero bounds, enum constructor coverage,
generic/recursive/dependent deriving, proof fields, dependent pairs, impossible
domains, local instance overrides, default recursive sizes, decidable propositions,
imported/local registration, and exact shrinking
and replay of constrained values and function arguments.

`python3 scripts/test_elaboration.py` checks nine compiler rejection paths.
`python3 scripts/test_downstream.py` builds a separate Lake consumer with derived
types and tests in an imported module. It runs `lake test`, then verifies that a
deliberately false generated property shrinks to 5 and exits with status 1.
