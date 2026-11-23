# November 23, 2026 maintenance

The public frontend uses Lean 4.36.0 and libhegel 0.43.1. The
[weekly CI run](https://github.com/alok/hegel-lean/actions/runs/45216724892)
passed on Linux x86-64, Linux ARM64 and macOS ARM64. Lean 4.36.0 is still
the latest stable compiler. The reviewed reference head is still
`603eec1c70f4f6e1e445cdf0847c6723fd63997e`.

## Libhegel 0.53.1 candidate

The local branch `codex/libhegel-0.53.1-candidate` at
`f6039c89e9bb649827fc7f678909b05c7906079f` uses engine source
`cc7d4211856cb6f1bad12ab86c95d1f84421f308`. Its lock contains release digests
for the header and all three platform archives. The macOS ARM64 archive and
header matched their digests on download.

The candidate adapts two ABI changes.

- [0.52.0](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.52.0)
  replaces the capture query with an output-interest query and requires a
  failure summary and diagnostic when completing a case. The bridge sends a
  single-line summary and the complete message through length-delimited
  strings. Empty failure origins use the existing reversible origin encoding.
- [0.53.0](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.53.0)
  adds precision and date-filter arguments. The bridge selects nanoseconds
  and unrestricted dates, preserving the Lean types' domains.

The new reporting regression checks 36 combinations of verbosity, origin and
message, including empty strings, multiple lines, Unicode and embedded NULs.
Every failure retained its exact origin and message and replayed. Debug output
retained both lines of the ordinary multiline message and the suffix after an
embedded NUL. The engine sanitizes control characters in terminal output.
Existing checks cover nanosecond precision, calendar bounds and single-case
workloads with choice recording disabled.

The candidate passed the required build, integration, ABI, port inventory,
elaboration, panic, concurrency and downstream checks on macOS ARM64. This
covered 48 native signatures, 165 API targets, all nine compiler rejection
checks and all 39 fixed MacIver regressions. Three of six separate discovery
probes missed a bug. All three fuzz smoke commands also passed.

## Shrinking results and pin decision

The adjacent-UInt64 diagnostic ran seeds 0–199 with 1,000 examples per seed.
It exited 1, with 171 minimal witnesses, 27 nonminimal witnesses, two discovery
misses and zero engine or replay errors. All 198 found witnesses replayed twice.

Every per-seed record matched the
[November 9 candidate receipt](adjacent-sweep-results-2026-11-09.json),
including witnesses, evaluation counts, outcomes and replay counts.
Seeds 88 and 120 still missed their failure. The published engine found and
minimized both in the [November 16 comparison](maintenance-2026-11-16.md).

The decision to retain 0.43.1 accounts for those discovery regressions and the
engine-version requirement on existing replay tokens. The published engine
also has nonminimal shrinking results. The 0.53.1 candidate was evaluated
locally on macOS ARM64. Hosted CI covers the published engine pin.
