# Hegel for Lean 4

[![CI](https://github.com/alok/hegel-lean/actions/workflows/ci.yml/badge.svg)](https://github.com/alok/hegel-lean/actions/workflows/ci.yml)

A Lean 4 frontend for [Hegel](https://hegel.dev): write generators and properties in Lean,
then let Hegel generate inputs, shrink failures, and save counterexamples for the next run.

```lean
import Hegel
open Hegel Hegel.Property

def reverseTwice : Property Unit := do
  let xs ← forAll (Gen.list (Gen.int (-100) 100) 0 40) "xs"
  assertEq xs.reverse.reverse xs "reverse is involutive"

def main : IO Unit := check! "reverse twice" reverseTwice
```

The implementation uses the current **native libhegel C API**, with a small C bridge and a
Lean library. No Haskell, Python testing server, or Rust compiler is needed at runtime.
The Haskell [zizek](https://github.com/MercuryTechnologies/zizek) client informed the API and
lifecycle design; this is an independent implementation, not a complete port of zizek.

## Install and run

Requirements: [elan](https://github.com/leanprover/elan), a C compiler, Python 3, and curl.
On macOS, install the Xcode command-line tools. Lean is pinned to **4.34.0** and libhegel to
**0.43.1**. The first native build downloads the platform's static engine archive and header
and verifies their SHA-256 digests against [`engine-lock.json`](engine-lock.json).
Subsequent builds reuse and recheck those files. Cached builds can run offline.

```sh
git clone https://github.com/alok/hegel-lean.git
cd hegel-lean
lake build hegel_tests hegel_examples
lake test
lake exe hegel_examples
lake exe hegel_examples fail  # deliberately exits 1; shrinks n to 5
```

Supported targets are Linux x86-64, Linux ARM64, and Apple Silicon macOS. CI exercises all three.
Windows and Intel macOS are not yet supported by the build integration.

In another Lake project using the same Lean toolchain, add:

```lean
require «hegel-lean» from git "https://github.com/alok/hegel-lean" @ "main"
```

Run `lake update` once and commit your `lake-manifest.json` to retain the resolved revision.
The engine is fetched relative to this dependency, and native linking propagates to the
consumer's executable. [`scripts/test_downstream.py`](scripts/test_downstream.py) tests that path.
Properties currently run in compiled Lake executables; interactive `#eval` is not supported.

## Generators

`Gen α` supports `pure`, `<$>`, `<*>`, and `do` notation. Later draws can depend on earlier values:

```lean
def interval : Gen (Int × Int) := do
  let lo ← Gen.int (-1000) 1000
  let hi ← Gen.int lo (lo + 100)
  return (lo, hi)
```

| API | Values / behavior |
| --- | --- |
| `Gen.bool probability` | Boolean, default probability `0.5` |
| `Gen.int min max`, `Gen.nat min max` | Inclusive, arbitrary-precision bounds |
| `Gen.fin n positive` | `Fin n` with a checked bound proof |
| `Gen.float config` | IEEE binary64, configurable bounds, NaN and infinities |
| `Gen.text config`, `Gen.char` | Unicode scalar values, including embedded NUL |
| `Gen.bytes minSize maxSize` | `ByteArray` |
| `Gen.regex pattern fullMatch` | Native engine regex generator |
| `Gen.email`, `Gen.url`, `Gen.domain maxLength` | Formatted text |
| `Gen.element values`, `Gen.oneOf choices` | Finite choice; empty input is an error |
| `Gen.option gen`, `Gen.pair a b` | Optional and paired values |
| `Gen.list gen min max`, `Gen.array gen min max` | Engine-managed variable-length collections |
| `Gen.vector gen n` | `Vector α n` with a checked length proof |
| `Gen.uniqueArray gen min max` | Uniqueness under the element's `BEq` instance |
| `Gen.filter predicate gen attempts` | Bounded retries, default three; then discard |
| `Gen.assume condition`, `Gen.discard` | Reject a case without reporting a failure |
| `Gen.recursive depth leaf branch` | Explicit depth-bounded recursion |
| `Gen.defer (fun () => gen)` | Delay generator construction |

Collection and text sizes default to `0..64`. Integer bounds are required; they never silently
wrap at 64 bits. Negative and positive integers beyond 200 bits are covered by integration tests.
Lists use Hegel's collection primitive so the engine controls both their lengths and shrinking.
Recursive generation uses a caller-supplied maximum depth, not Hegel's native recursion-budget API.

Functions can be ordinary generated values. Use `Property.draw` when a value has no `Repr` instance:

```lean
def shifted : Property Unit := do
  let f ← draw ((fun n x => x + n) <$> Gen.nat 0 100)
  assertEq (f 10 - f 0) 10 "shift preserves difference"
```

## Properties, reports, and replay

`Property.forAll` records a generated value in the final failure report. `draw` omits the
representation; `annotate` adds text. Assertions take a **stable origin string**: use a unique
name for each assertion, without generated values. Hegel groups and shrinks failures by this
origin. Put variable details in the optional message or annotations.

```lean
def bounded : Property Unit := do
  let n ← forAll (Gen.int 0 100) "n"
  assertThat (n < 5) "bounded/n-less-than-five" s!"Found {n}"

def inspect : IO Unit := do
  let report ← check "bounded" bounded { seed := some 42, database := none }
  IO.println report.render
  for failure in report.failures do
    let repeated ← replay failure.blob bounded
    IO.println (reprStr repeated)
```

This property fails and shrinks to `n = 5`. A property requiring list length below three
shrinks to `[0, 0, 0]`. Both exact results and replayed annotations are regression-tested.
Replay blobs are guaranteed only with the same engine version and compatible property code.

- `check` returns a structured `Report`; outcomes distinguish pass, failure, engine/health-check
  error, and nondeterministic failure. Reports include final replayed values and replay blobs.
- `check!` prints the report and throws an IO error for every non-passing outcome.
- `runTests` runs an array of named `Test` values and returns process exit code `0` or `1`.
- `assertProp p origin` tests a decidable Lean proposition. It does not prove it universally.
- `assume false` rejects a case. Excessive rejection triggers Hegel's health checks and cannot
  silently become a passing run.
- `Property.io action origin` runs IO on every execution, including shrinking and replay;
  IO exceptions become failures. Reset mutable state within each case and keep the property
  deterministic for the same draws.
- `target score label` guides Hegel toward larger finite scores.

The default database is `.hegel/examples`, keyed by the name passed to `check`. Use stable,
distinct test names. Set `database := none` for ephemeral tests. `Settings` also controls the
example count, optional seed, phases, multiple-failure reporting, and health-check suppression.
`Report.evaluations` counts body executions during the campaign, **including shrinking**;
it excludes the extra final replay used to collect annotations.

## Verification and trust boundary

`lake test` runs against the real pinned engine. It covers primitive bounds, arbitrary-size
integers, dependent draws, Unicode/NUL preservation, nested collections, recursive trees,
functions, minimal counterexamples, multiple failure origins, exact replay, persistence,
invalid configurations, IO errors, health checks, and native-handle lifecycle checks.

```sh
python3 scripts/check_ffi.py       # C signatures checked against Lean-emitted prototypes
python3 scripts/test_downstream.py # build and run a separate Lake consumer
```

The bridge owns and releases contexts, settings, runs, test cases, collections, result snapshots,
and returned buffers. Explicit close is idempotent; an external-object finalizer is a fallback.
Sessions reject access from a different OS thread and use after close. Independent campaigns can
run on separate threads, but a single property cannot perform generator draws on worker threads.

Lean checks the frontend's types and the proof fields in `Fin` and `Vector`. This is **not a
formal verification of Hegel or the C bridge**. The engine, compiler/runtime, native ABI, and C
ownership code remain trusted. There are no `sorry` proofs or user-defined logical axioms.

`lake test` also includes [regressions derived from David R. MacIver's blog](docs/maciver-tests.md):
13 scenarios across three seeds, including the 70-copies-of-10 stress case, dependent generators,
Unicode, and distinct NaN/empty-list failures. Two additional discovery probes preserve observed
coverage misses in the output. Run `lake exe hegel_maciver_tests` for just this suite. CI uploads
machine-readable results for every supported platform.

The public API intentionally covers single-threaded properties and compositional generators.
Native concurrent state machines, pools, calendar/UUID generators, source-location macros,
and pretty-printer bindings are not implemented. No claim of full zizek API parity is made.

## Maintenance and sources

CI runs on pushes, pull requests, manual dispatch, and weekly. To update the engine pin:

```sh
python3 scripts/update_engine.py
lake build hegel_tests hegel_examples
lake test
python3 scripts/check_ffi.py
python3 scripts/test_downstream.py
```

Review upstream changes, refresh the version notes and compatibility documentation, and commit
only after checks pass. An engine release tag, source commit, artifact URLs, and SHA-256 hashes
are kept in `engine-lock.json`. Builds never silently follow upstream `main`.

- Engine/C ABI: [hegel-rust at 9a130bf](https://github.com/hegeldev/hegel-rust/tree/9a130bfde99005504b0004428e047803ac18d3a0/hegel-c)
- Haskell design reference: [zizek at 6b25365](https://github.com/MercuryTechnologies/zizek/tree/6b25365f6c6e2d9bbe6970a3eb892ba4c076e241/library/Hegel)
- The archived [hegel-core](https://github.com/hegeldev/hegel-core) subprocess implementation is
  not a dependency; its README directs users to the native API.

MIT licensed. See [LICENSE](LICENSE) and the upstream engine's [license](vendor/HEGEL-LICENSE).
This is an independent frontend, not an official Hegel or Mercury Technologies release.
