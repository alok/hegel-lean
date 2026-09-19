# Settings, assertions, and reports

This page describes the Lean frontend's configuration and reporting APIs. The full feature
inventory, including generator and stateful APIs, is in
[`scripts/port-api.json`](../scripts/port-api.json). Executable regression coverage for this page
is in [`Tests/Reporting.lean`](../Tests/Reporting.lean).

## Source-aware assertions

Import `Hegel.Assertion` to use assertions that capture the calling Lean module, line, and column:

```lean
import Hegel.Assertion
import Hegel.Runner

open Hegel Hegel.Property

def reverseTwice : Property Unit := do
  let values ← forAll! (Gen.list (Gen.nat 0 100) 0 20)
  assertEq! values.reverse.reverse values
  assert! (values.length ≤ 20) because "generator length bound"
  assertProp! (values.length ≤ 20)

def main : IO Unit := check! "reverse twice" reverseTwice
```

`assertEq! actual expected` attaches a structural difference when the rendered values have
matching list, tuple, or record shapes. Other representations use a line difference. Removed
lines describe the actual value; added lines describe the expected value. `assertNe! a b`
requires unequal values, and `failure! message` fails unconditionally.

Origins contain the module name and source position. They exclude generated values and exception
messages, so shrinking does not split one assertion into many unrelated failures. The module name
also keeps origins stable when the repository is built under a different absolute path. Source
files and complete start/end positions remain in the evidence for optional source listings.

The same assertion macros work in ordinary `IO`, including callbacks passed to `Property.forEach`:

```lean
def checkedCallback : Property Unit :=
  Property.forEach (Gen.nat 0 100) fun n => do
    assertEq! (n + 0) n
```

`Assertion.MonadAssertion` provides the effect interface. The `Property` instance records evidence
directly. The `IO` instance uses a dedicated error code and a versioned JSON envelope; `Property.io`
restores its source, difference, and failure origin. An ordinary `IO.userError` containing similar
text is still an ordinary exception. UTF-8 strings and embedded NULs survive the envelope.

The explicit-origin APIs remain available: `Property.assertThat`, `assertEq`, `assertNe`,
`assertProp`, and `failure`. Use a stable name for their origin argument, and put changing values
in messages or annotations.

## Run settings

```lean
def ciSettings : Settings := {
  maxExamples := 1000
  database := none
  databaseKey := some "reverse-twice"
  derandomize := true
  phases := #[.generate, .target, .shrink]
}
```

| Setting | Default | Behavior |
| --- | --- | --- |
| `maxExamples : UInt64` | `100` | Budget for valid generated cases; shrinking adds executions. |
| `statefulStepCount : Nat` | `50` | Stateful step budget; must be at least one. |
| `seed : Option UInt64` | `none` | Explicit seed, or fresh randomness unless derandomized. |
| `derandomize : Bool` | `false` | Derives randomness from test identity when no explicit seed exists. |
| `database : Option FilePath` | `some ".hegel/examples"` | Persistence directory; `none` disables it. |
| `databaseKey : Option String` | `none` | Overrides the run name as persistent test identity. |
| `phases : Array Phase` | All five | Explicit, reuse, generate, target, shrink. |
| `backend : Backend` | `.default` | Seeded PRNG, `.urandom`, or environment-selected `.auto`. |
| `verbosity : Verbosity` | `.quiet` | Quiet, normal, verbose, debug; engine output is captured. |
| `reportMultipleFailures : Bool` | `true` | Retains distinct failure origins. |
| `suppressHealthChecks : UInt32` | `0` | Original health-check bitmask API. |
| `suppressHealthCheck : Array HealthCheck` | `#[]` | Typed suppressions, combined with the bitmask. |
| `maxCloneDepth : Nat` | `32` | Nesting limit for concurrent clone streams. |
| `showStatistics : Bool` | `false` | Requests engine statistics output. |
| `unboundedChoices : Bool` | `false` | Removes the engine's per-case choice limit. |
| `printBlob : Bool` | `true` | Controls the engine's reproduction-output setting. |

`Settings.validate` returns a structured `SettingsError` before a campaign starts. It rejects
zero or overflowing stateful limits, unsupported health-check bits, and NUL-containing database
paths or keys. Negative counts cannot be represented by the public natural-number types.

`HealthCheck` has `filterTooMuch`, `tooSlow`, `testCasesTooLarge`, and `largeInitialTestCase`.
Suppressing a health check does not make an exhausted or wholly rejected campaign pass. A run
with zero completed valid cases returns an error, including a zero example budget or phases that
perform no useful work. `.explicit` is exposed because it is part of the engine phase mask; the
pinned engine currently reserves that phase and has no explicit-example queue.

An explicit seed takes precedence over `derandomize`. `.auto` selects `.urandom` when
`ANTITHESIS_OUTPUT_DIR` is present and `.default` otherwise. The urandom backend uses external
entropy rather than the supplied seed.

## Evidence and cleanup

`check` returns a `Report`; `check!` prints it and raises an error unless it passed. `runTests`
collects named tests into an exit code suitable for `lake test`.

`Report.evaluations` counts body executions during generation and shrinking. Final reconstruction
is separate. `Report.stats` distinguishes valid, rejected, and overrun executions, with optional
explicit-replay accounting. Failures keep their stable origin, replay blob, final notes, and
structured trace.

`FailureEvidenceStatus` distinguishes reconstructed counterexamples, replay divergence, skipped
reconstruction, and failures observed in nondeterministic runs. `ReplayReason` explains unexpected
success or discard, exhausted choices, changed origins, invalid blobs, reconstruction errors,
missing data, and incompatible engine versions. A concurrent state-machine failure may have
observed evidence without a deterministic replay blob.

`Property.registerFinalizer` records per-case cleanup in reverse registration order.
`Property.resource` acquires a value during setup and registers its release operation. Every
registered release is attempted, and `CleanupDiagnostic` retains every exception. Cleanup failure
stops further execution instead of treating the campaign as successful. When the body already
failed, its original failure identity is retained alongside cleanup diagnostics.

## Structured notes and traces

`Property.forAll` records drawn values; `forAllWith` supplies a custom renderer, `forAllWithLabel`
adds an explicit label, and `forAllSilent` draws without rendering. `annotate`, `annotateShow`, and
`footnote` add context. Footnotes render after the main journal.

Each `Note` has a kind, text, optional source position, nesting depth, and clock. Note kinds also
represent stateful step headers, responses, failures, concurrent branch headers, worker origins,
and round boundaries. Draw numbers restart within each step or branch.

`Trace.build notes events` combines the note journal with `PoolEvent` records by their shared
clock. A trace exposes steps, pool identities, and the failing step. `Trace.root` follows transfer
lineage, and `Trace.displayName` preserves a value's original name across pool transfers.

`Trace.layoutRows` retains failing steps and steps that touch the same value lineage. Unrelated
runs become counted elision rows. If the failure touches no pool values, all steps remain visible.
The event log retains round, worker, and concurrency-group information.

## Rendering

`Report.render` is pure plain text. `renderAnsi` adds terminal colors; `renderRich` and
`renderRichWith` can read source snippets, with a plain location fallback when files are unavailable.
`renderAuto` selects output presentation from the environment.

`ReportStyle` configures ASCII or Unicode, color, source context, value/source line budgets, call
width, and custom `GlyphTable` and `PhraseTable` values. ASCII cleaning covers user values and
file names as well as decorative glyphs. Unknown non-ASCII scalars are escaped as `\u{...}`.
Value line budgets never remove failure evidence. `HEGEL_GLYPHS=ascii` or `unicode` overrides
automatic glyph selection.

The component APIs are also usable independently:

```lean
def inspectFailure (failure : Failure) : IO Unit := do
  let style : ReportStyle := { preference := .ascii, color := false }
  IO.println (Journal.renderWith style failure.notes)
  IO.println (Trace.renderWith style failure.trace)
```

Run the focused configuration, assertion, and reporting suite with:

```sh
lake exe hegel_reporting_tests
```
