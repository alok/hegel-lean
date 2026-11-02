# November 2, 2026 engine review

Main keeps **libhegel 0.43.1** and **Lean 4.35.0**. The new libhegel 0.49.0
candidate passes the frontend acceptance suite on macOS ARM64 after two bridge
changes, but it still fails the 200-seed shrinking diagnostic. That limitation
also affects 0.43.1. [Lean 4.35.0](https://github.com/leanprover/lean4/releases/tag/v4.35.0)
remains the latest stable Lean release; the API reference head remains
`603eec1c70f4f6e1e445cdf0847c6723fd63997e`, unchanged since the
[October 26 review](maintenance-2026-10-26.md).

## Compatibility with 0.49.0

The [October 28 engine release](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.49.0)
resolves to `56b7667eb1260715557ed59e0b736d1d0eece09c`. The local branch
`codex/libhegel-0.49.0-candidate` at `1bee0d11fab13ec01eca972e68ed1a5a844c35f5`
records the official header and archive digests for all supported platforms.
The macOS ARM64 archive and header were downloaded and hash-verified.

- The previous bridge failed to compile because the C header renamed
  `HegelRecursion` to `hegel_recursion_t`. The candidate uses the new type
  with the same constructor, operations, and matching release function.
- The engine now interprets `2^64 - 2` as a request for its default maximum.
  With a minimum of 100 and that explicit maximum, byte samples from the
  unadapted candidate never exceeded 100. For bytes, plain text, alphabet text,
  and collections, the bridge now passes `UINT64_MAX` for explicit maxima
  at or above the reserved value, as required by the header. Lean's ordinary
  size defaults are unchanged.

The [regression test](../Tests/Generators.lean) draws 32 samples for each of the
four paths with seed 42 and checks that each can exceed 100. It passes on the
published 0.43.1 pin and the adapted 0.49.0 candidate. The test is on main;
the new C bridge and lock are only on the local candidate branch.

## Validation and pin decision

Both configurations passed the test and example builds, `lake test`, the FFI
and port inventory checks, compiler rejection tests, panic and concurrency
checks, and the downstream Lake consumer on macOS ARM64. These cover deriving,
proof-carrying generators, property syntax, and imported test registration. All
39 fixed MacIver regressions passed in each configuration. Four of six discovery
probes missed a bug on 0.43.1; three of six missed on 0.49.0. FFI validation
covered 46 Lean/C signatures on main and 48 on the candidate.

The candidate's unchanged `hegel_adjacent_sweep` executable ran seeds 0–199,
with 1,000 examples per seed, no database, and two replays of each found
counterexample. The diagnostic **exited 1**:

| Minimal | Nonminimal | Discovery misses | Engine or replay errors |
| ---: | ---: | ---: | ---: |
| 171 | 27 | 2 | 0 |

Seed 6 stopped at `(1549, 1548)` after 9,444 evaluations. Seeds 88 and 120
missed the failure. All 198 found counterexamples replayed twice. The
[per-seed results](adjacent-sweep-results-2026-11-02.json) match the 0.48.0 run
in every row, including witnesses and evaluation counts. The candidate was not
pushed or run in the hosted CI matrix. The [main workflow](../.github/workflows/ci.yml)
tests the published pin on Linux x86-64, Linux ARM64, and macOS ARM64.
