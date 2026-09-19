# Generators

Import `Hegel` for the complete API. A `Gen α` describes a value of type `α`; drawing it
records the native choices that Hegel later replays and shrinks. Ordinary Lean `do`
notation supports generators whose later bounds depend on earlier values.

```lean
import Hegel
open Hegel

namespace GeneratorExamples

def orderedPair : Gen (Int × Int) := do
  let lower ← Gen.int (-100) 100
  let upper ← Gen.int lower (lower + 100)
  return (lower, upper)
```

The direct API keeps bounded generators concise. The typed configuration API puts
constructors in `Gen.Builder`, modifiers in `Gen`, and materializes a configuration
with `Gen.build`:

```lean
def smallInt8 : Gen Int8 :=
  Gen.build <| Gen.max (20 : Int8) <| Gen.min (-20 : Int8) Gen.Builder.int8

def probability : Gen Float32 :=
  Gen.build <| Gen.exclusiveMin <| Gen.exclusiveMax <|
    Gen.max (1 : Float32) <| Gen.min (0 : Float32) Gen.Builder.float32

def identifier : Gen String :=
  Gen.build <| Gen.minSize 1 <| Gen.maxSize 20 <|
    Gen.alphabet Alphabet.alphaNum Gen.Builder.text
```

Modifiers have types: `Gen.maxSize` accepts collection builders, `Gen.minYear`
accepts dates and datetimes, and `Gen.disallowNaN` accepts floating-point builders.
Applying one to an unrelated builder is a Lean type error. Setting either floating
bound excludes NaN; setting both also excludes infinity. Direct `Gen.float` and
`Gen.float32` take explicit `FloatConfig` flags instead.

`Gen.int` supports arbitrary precision when both bounds are supplied. The signed
8/16/32/64-bit, unsigned 8/16/32/64-bit, `ISize`, and `USize` generators cover their
complete machine ranges. `Gen.float` produces Lean `Float` (binary64), and
`Gen.float32` draws at native binary32 precision before converting to Lean `Float32`.

Builder collection limits default to zero through the engine's UInt64 maximum;
nonempty builders default to one. The existing direct collection functions retain
their default maximum of 64. Native choice and rejection budgets still bound a test
case. Give practical upper limits to keep a generated value readable.

# Collections and finite choices

Lists and arrays preserve generation order. `Gen.nonEmpty` returns `NonEmptyList α`
with a separate head and tail. Tree containers use Lean's `Ord` comparison; hash
containers use `BEq` and `Hashable`. Integer container aliases use Lean's unbounded
`Int`. Container sizes count distinct elements or keys.

```lean
def lookupTable : Gen (Std.TreeMap String Nat) :=
  Gen.build <| Gen.minSize 2 <| Gen.maxSize 12 <|
    Gen.Builder.map identifier (Gen.nat 0 1000)

def distinctBytes : Gen (List UInt8) :=
  Gen.build <| Gen.minSize 4 <| Gen.maxSize 4 <|
    Gen.unique (· == ·) (Gen.Builder.list Gen.uint8)

def uniqueModuloTen : Gen (Array Nat) :=
  Gen.uniqueArrayBy (fun a b => a % 10 == b % 10) (Gen.nat 0 99) 3 5
```

Duplicate keys are rejected **before** drawing values. Duplicate rejection does not
consume a collection slot. Exact-size unique collections internally request variable
size, allowing rejection to advance the native choice stream, and trim a possible
extra entry to the requested maximum. Ordered sets and maps retain the least elements
or keys; hash containers trim in their own native iteration order. The frontend also
has a defensive iteration
bound of `100 * (maxSize + 1)` for duplicate-rejecting loops; exhaustion discards the
case. Asking for more distinct values than a generator can produce does not yield a
shortened successful result.

`Gen.element`, pure values, mapping, applicative composition, and `Gen.oneOf` retain a
lazy finite enumeration. `Gen.enumerate` returns `none` for a generator whose support
is unknown, including monadic dependency and `Gen.defer`. A finite enumeration
preserves repetitions and choice order; it is not a mathematical set.

```lean
def evenDigit : Gen Nat :=
  Gen.filtered (fun n => n % 2 == 0) (Gen.element #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9])

def positiveOption : Gen Nat :=
  Gen.just (Gen.element #[none, some 1, some 2])

def weightedChoice : Gen String :=
  Gen.frequency #[(10, pure "ordinary"), (1, pure "rare")]
```

`Gen.filtered` and `Gen.mapMaybe` precompute a finite source's accepted values.
Thus a rare acceptable member of a finite choice is available immediately instead
of being missed by a small retry budget. For a source without finite metadata,
`Gen.mapMaybe` makes three attempts by default, marking unsuccessful mapping spans
discarded. A discard raised by the source itself propagates immediately. The older
`Gen.filter` remains a direct bounded-retry operation.

Weights must be positive. They bias native branch choices but do not guarantee a
long-run sampling distribution: Hegel explores new choice sequences and can exhaust
a low-entropy branch. Use `Gen.either` for sums, `Gen.option` for optional values,
and `Gen.Enumeration` with `Gen.enumBounded` for a finite user type.

# Unicode and structured values

An `Alphabet` combines a codec, inclusive codepoint bounds, Unicode general
categories, explicit inclusion, and explicit exclusion. Category names use the
standard two-letter identifiers such as `.Lu`, `.Ll`, and `.Nd`. `categories` and
`excludeCategories` are mutually exclusive. Explicit inclusion is applied before
explicit exclusion, and native generation always removes surrogate codepoints.

```lean
def restrictedText : Gen String :=
  ({ Alphabet.lower with
    includeCharacters := "0\x00"
    excludeCharacters := "a" }).text 1 20

def threeLetters : Gen String :=
  Gen.build <| Gen.fullMatch <|
    Gen.alphabet Alphabet.lower (Gen.Builder.regex ".{3}")
```

The twenty presets cover ASCII, printable ASCII, letter/digit subsets, binary,
octal, hexadecimal, Latin-1, Unicode, ASCII punctuation, base64, base64url, URI
unreserved characters, whitespace, combining marks, zero-width characters, and
bidirectional controls. `Alphabet.only` and `Alphabet.ranges` define custom sets.
Ranges include valid scalars from their inclusive bounds; values beyond Unicode's
maximum and surrogate values are omitted.

Text sizes count Unicode scalar characters. Strings and generated buffers preserve
embedded NUL bytes, including a one-character `"\x00"` alphabet. Parameters that the
native API accepts as C strings, such as regex patterns, reject embedded NULs.
Regex alphabets constrain wildcard and padding choices using the native engine.

`Gen.uuid` returns a `UUID` containing exactly 16 bytes. An optional version in
`0..15` fixes the version nibble and RFC variant; no version requests native
unconstrained non-nil UUID generation. Its renderer uses the usual 36-character
hyphenated representation. `Gen.email`, `Gen.domain`, and `Gen.uriText` expose the
native format generators. `Gen.uri` parses the generated absolute HTTP(S) URI into
scheme, authority, path, optional query, and optional fragment. `URIAuth` separates
encoded user information, host (including bracketed IP literals), and explicit port
text, preserving details such as leading port zeros and an empty fragment. It validates
percent escapes, component character syntax, and bracketed IP literals. It is not a
general-purpose parser for every URI scheme.

# Calendar values and exact durations

Dates use the proleptic Gregorian calendar and years `-999999..999999`, including
year zero. `Date.valid` checks the month, day, and Gregorian leap-year rule. Time
fields have nanosecond resolution, no timezone, and no leap-second representation.
The native engine validates and generates complete calendar values, rather than
independently drawing fields that might form an invalid date.

```lean
def leapYearDate : Gen Date :=
  Gen.build <| Gen.minYear 2024 <| Gen.maxYear 2024 Gen.Builder.date

def onLeapDay : Gen DateTime :=
  Gen.build <| Gen.onDay ⟨2024, 2, 29⟩ Gen.Builder.datetime

def crossesMidnight : Gen DateTime :=
  Gen.datetime ⟨⟨2024, 2, 29⟩, ⟨23, 59, 59, 999999998⟩⟩
    ⟨⟨2024, 3, 1⟩, ⟨0, 0, 0, 1⟩⟩

def longExactDuration : Gen Duration :=
  Gen.duration ⟨2 ^ 100 + 1⟩ ⟨2 ^ 100 + 1000⟩

def betweenThirtySecondsAndTwoHours : Gen Duration :=
  Gen.build <| Gen.min (Duration.seconds 30) <| Gen.max (Duration.hours 2)
    Gen.Builder.duration
```

Datetime bounds compare the date first and the time second. For business hours on
every date, compose `Gen.date` and `Gen.time` independently. Date and datetime draws
shrink toward the start of 2000, clamped to the supplied interval; times shrink
toward their lower bound.

`Duration.picoseconds` is an exact arbitrary-precision `Int`; generation rejects
negative bounds. Durations support single picoseconds and values above UInt64.
`Duration.milliseconds`, `.seconds`, `.minutes`, and `.hours` accept exact `Rat`
unit counts, including decimal literals such as `1.5`. Sub-picosecond fractions round
down to the representable picosecond; `Duration.exactSeconds?` returns `none` instead
when that conversion would lose precision. You can also supply picoseconds directly.
The default maximum
is the exact interval between the two extreme supported dates, `730484633` days.

# Native recursive generation

Use `Gen.Builder.recursive` when a value has a meaningful shared leaf budget.
It provides the branch's depth and the configured maximum depth, plus a generator
for a child. Depth zero means the whole value must be a leaf.

```lean
inductive Tree where
  | leaf (n : Nat)
  | fork (left right : Tree)
  deriving Repr

def tree : Gen Tree :=
  Gen.build <| Gen.maxDepth 5 <| Gen.maxLeaves 20 <|
    Gen.Builder.recursive (Tree.leaf <$> Gen.nat 0 100) fun _ child =>
      Tree.fork <$> child <*> child

end GeneratorExamples
```

The native recursion primitive decides branch versus leaf, tracks leaf usage across
all siblings, and retries an entire value if a branch exceeds its budget. It also
retries when the observed branch arity disagrees with the engine's initial estimate.
Branches may use a variable number of child draws, including zero. Retry control
unwinds through generated computations without being mistaken for a passing test,
an assertion failure, or an ordinary engine error. The engine owns span cleanup for
those retry signals; the frontend releases the recursion handle on every exit.

The existing `Gen.recursive depth leaf branch` helper still offers a depth-only
construction. Use the builder above when the total number of leaves matters.

# Validation and verification

New generator configuration errors and typed builder validation become shrinkable
counterexamples with stable `generator/<family>` origins. Native engine failures,
invalid output representations, and out-of-range generated values remain errors.
The original direct API retains its earlier configuration-error behavior where
stated in its docstrings; it does not silently turn such errors into passes.

The focused suite is part of `lake test` and can also run on its own:

```sh
lake exe hegel_generator_tests
```

It includes machine widths, floating-point bounds, all alphabet presets, NUL text,
calendar boundaries, exact durations, UUID versions, URI roundtrips, collection
uniqueness, finite filtering, and recursive depth/leaf budgets. Dedicated recursion
cases exercise an oversized five-child branch with a three-leaf budget and a branch
with zero children. Calendar, duration, and tree counterexamples shrink to checked
minima and replay twice; invalid configurations also replay their failure origins.

The API uses Lean data types and compiler-checked bounds where available. It does
not promise identical seeded traces, hash-container order, or internal algorithms
to another frontend. Native engine pins and verification commands are recorded in
[`engine-lock.json`](../engine-lock.json) and the [README](../README.md).
