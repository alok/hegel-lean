# Regression tests from David R. MacIver's writing

The suite in [Tests/MacIver.lean](../Tests/MacIver.lean) runs against the pinned native engine.
It contains 13 regression scenarios and two discovery probes, each run with seeds **0, 1, 42**.
The false properties are intentional: a regression passes only if Hegel finds the specified
failure, returns the expected minimal witness, and reproduces it twice. The UTF-8 roundtrip
is a passing control. Any wrong failure origin, engine error, changed replay, or broken generator
invariant fails the suite.

```sh
lake test                                      # existing tests + this suite
lake exe hegel_maciver_tests                    # focused suite
lake exe hegel_maciver_tests .lake/results.json # also write structured results
lake exe hegel_maciver_tests .lake/results.json 42 # one seed
```

`lake test` writes `.lake/maciver-results.json`; CI uploads that file for each platform.
Discovery probes print `MISS` when they do not find a known bug. A miss is an observed search
limitation, not a correctness failure of the library, and does not turn CI red. Such misses
remain in both the console summary and JSON; they are never counted as passing regressions.

## Sources and test contracts

The source posts were read on 2026-09-18. These are independent Lean adaptations, not copied
Python implementations. The table distinguishes the author's concrete examples from tests
constructed to exercise his design ideas.

| Source | Scenario | Contract and adaptation |
| --- | --- | --- |
| [Honey I shrunk the clones](https://drmaciver.com/2015/04/honey-i-shrunk-the-clones/) (2015-04-01) | `duplicate-triples` | Find a list containing at least three equal entries; reduce to `[0, 0, 0]`. Integers bounded to `[-100,100]`, length to 20. |
| Same post | `seventy-large-elements` | Preserve the post's condition: at least 70 entries are at least 10. Expect exactly 70 copies of `10`. Draw length in `0..100` first, then that many integers in `0..1000`. The default-length distribution is measured separately below. |
| [A pathological example for test-case reduction](https://drmaciver.com/2018/01/a-pathological-example-for-test-case-reduction/) (2018-01-20) | `nearby-uint64`, `adjacent-uint64` | Use the original unsigned 64-bit range and falsify distance greater than one. Expect `(0,0)`; a second variant excludes equality and expects `(0,1)` or `(1,0)`. These do **not** establish worst-case complexity or force a large initial pair. |
| [Monadic data generation strategies](https://drmaciver.com/2015/02/monadic-data-generation-strategies-and-why-you-should-are/) (2015-02-24) | `non-injective-map`, `shared-timezone` | New regressions for two ideas in the post: a lossy integer division map shrinks to `1`; a list of simple timestamp records shares one generated offset throughout shrinking. The two-record minimum has offset and minute zero. This is not timezone/calendar library testing. |
| [Conjecture, parametrization and data distribution](https://drmaciver.com/2015/11/conjecture-parametrization-and-data-distribution/) (2015-11-27) | `irrelevant-option`, `first-branch`, `filtered-draw` | An irrelevant optional collection reduces to `none`; ordered alternatives choose the first branch; rejected draws never escape the filter and the accepted minimum is `10`. These exercise public behavior, not the historical parametrization algorithm. |
| [The easy way to get started with property based testing](https://drmaciver.com/2016/03/the-easy-way-to-get-started-with-property-based-testing/) (2016-03-03) | `astral-text`, `unicode-roundtrip` | New Unicode regressions: falsify a BMP-only assumption, retaining a single astral character; verify UTF-8 roundtrips. The observed minimum is U+10000, but the oracle requires a single astral scalar, not that specific codepoint. |
| [A new approach to property based testing](https://drmaciver.com/2015/09/a-new-approach-to-property-based-testing/) (2015-09-02) | `interleaved-effects` | New test of draws interleaved with IO: store one draw, read it back, use it as a later bound. State is reset on every execution; minimum `(lo, saved, hi)` is `(0,0,5)`. |
| [When multiple bugs attack](https://hypothesis.works/articles/multi-bug-discovery/) (2017-09-26), MacIver's Hypothesis blog post | `multiple-bugs` | Adapt the mean-between-min-and-max example with two stable origins. Require both empty input and a singleton NaN, each shrunk and replayed independently. The regression adds a NaN branch to native float generation; the unmodified native distribution is probed separately. Replay also checks raw float bits, since `NaN != NaN`. |

## Discovery measurements

The initial direct translations exposed two cases where a false property was not reliably
falsified. We retained those exact distributions as separately reported probes rather than
weakening the failure predicates or pretending every bug was found.

| Probe | Seed 0 | Seed 1 | Seed 42 |
| --- | --- | --- | --- |
| Default list length `0..100`, count at least 70 entries ≥10 | Miss | Miss | Miss |
| Native floats only, empty-list and arithmetic failure origins | Both found | Both found | Empty-list only |

The list probe exhausted 1,000 valid examples on each seed. libhegel's current length model
strongly favors small lists: its [length distribution](https://github.com/hegeldev/hegel-rust/blob/9a130bfde99005504b0004428e047803ac18d3a0/hegel-c/src/native/core/state.rs#L159)
uses an average around five for this range. The targeted regression changes the distribution
by drawing the length explicitly; it retains the same list domain and failure predicate.

The float probe at seed 42 finished after 31 evaluations with just the empty-list origin.
Increasing `maxExamples` alone does not guarantee more exploration once a bug is found:
the [engine's post-failure generation heuristic](https://github.com/hegeldev/hegel-rust/blob/9a130bfde99005504b0004428e047803ac18d3a0/hegel-c/src/native/test_runner.rs#L827)
can stop sooner. The targeted regression adds a NaN-producing branch so both origins can be
exercised across the chosen seeds. Multiple-failure reporting preserves discovered origins;
it does not guarantee discovery of every possible bug.

## Results and boundaries

The [checked-in local receipt](maciver-results.json) records a run on Apple Silicon macOS,
Lean 4.34.0, libhegel 0.43.1. It records **39 passing regression runs, six discovery probes,
and four discovery misses**. Each found counterexample was independently replayed twice.
The per-seed receipts include evaluation counts, elapsed milliseconds, and witnesses. The
first witness is recorded for the generic minimum tests; it is explicitly unrecorded for
the multi-origin test.

The 70-element campaigns took roughly two seconds each on this machine and about 29,000 body
evaluations, including generation and shrinking. Those are local measurements, not a portable
performance guarantee or a reproduction of the historical implementation's benchmark. No
five-second assertion is imposed on CI. Each generic campaign has an explicit 150,000-body-call
guard, and each CI job has a ten-minute timeout.

The JSON is a snapshot; live CI results are uploaded as `maciver-results-<runner>` artifacts.
The fixed seeds and witness contracts provide regression coverage, not exhaustive validation
of the engine, statistical confidence in bug detection, or a proof of optimal shrinking on
all inputs. The initial addition of this suite required no production library changes;
later frontend revisions rerun it as a regression suite.
