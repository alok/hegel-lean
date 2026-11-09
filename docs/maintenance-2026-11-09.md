# November 9, 2026 maintenance

Main uses libhegel 0.43.1 and Lean 4.35.0. The November 4 frontend changes are
included in this review. Lean 4.35.0 is the latest stable release and the
API reference head is still `603eec1c70f4f6e1e445cdf0847c6723fd63997e`.

## Fuzz results

The invalid-configuration probes now check the expected validation origin,
error prefix, or exhaustion diagnostic. Injecting an unrelated runner error
into the inverted integer bounds probe used to give exit 0. The same injection
now gives exit 1 and identifies the failing probe.

The program and state-machine harnesses now check the status, origin,
annotations, and cleanup of all three direct replays of each counterexample.
They also encode and decode its replay token and check the resulting failure.
Filtered-out programs have their own count. A campaign needs at least one pass
or reproduced counterexample to succeed. For example, `lake exe hegel_fuzz_harness
3 1 100` exhausts its only program and now exits 1.

The local CI smoke campaigns produced these results. Each row had zero
unexpected failures.

| Engine and campaign | Passed | Failed and replayed | Exhausted |
| --- | ---: | ---: | ---: |
| 0.43.1, 200 random generator programs | 35 | 157 | 8 |
| 0.51.0, 200 random generator programs | 33 | 159 | 8 |
| 0.43.1 and 0.51.0, 50 random machines each | 38 | 12 | 0 |

## Engine review

[Libhegel 0.50.0](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.50.0)
split state-machine creation into construction, rule and invariant declaration,
and startup. [Libhegel 0.51.0](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.51.0)
uses a persistent pool of the maximum size and reports the active width each
round. The local candidate preserves rule indices by declaring rules in array
order, releases partially initialized machines on error, and lets every worker
poll its stream. A test with two to three workers caught a trace that always
reported the pool capacity. It passes with the active count from the engine.

The local branch `codex/libhegel-0.51.0-candidate` at
`95a2c446280c40a8c3861d4ea1392f887746addc` pins engine source
`53ac44fce46587bc68af419a76471dc1196d11ab`. Its lock records the official digests
for all three archives and the header. The macOS ARM64 archive and header matched
their digests after download.

Both configurations passed the macOS ARM64 builds, `lake test`, FFI and port
checks, compiler diagnostics, panic and concurrency checks, downstream Lake
consumer, release updater, and fuzz smoke tests. The checks covered 46 native
signatures on main and 48 on the candidate. All 39 fixed MacIver regressions
passed on both. Of six separate discovery probes, four missed on main and three
missed on the candidate.

The 0.51.0 adjacent-UInt64 sweep exited 1 across seeds 0–199. It found 171
minimal and 27 nonminimal witnesses and missed seeds 88 and 120. All 198 found
witnesses replayed twice, with zero engine or replay errors. Every per-seed
observation matched the November 2 run. The engine pin decision takes this
shrinking result into account. The retained 0.43.1 engine also exhibits
nonminimal shrinking. [November 9 results](adjacent-sweep-results-2026-11-09.json)
and [November 2 comparison](adjacent-sweep-results-2026-11-02.json).
