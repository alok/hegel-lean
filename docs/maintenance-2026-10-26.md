# October 26, 2026 maintenance

Main retains **Lean 4.35.0** and **libhegel 0.43.1**. Lean 4.35.0 remains the latest
stable release reviewed on October 26; 4.36.0-rc1 is a prerelease. This update fixes
confirmed frontend regressions and repairs release discovery after the engine's
move to a monorepo. The new **libhegel 0.48.0** candidate still fails the wider
shrinking diagnostic. The retained engine also has this defect; keeping its pin
does not establish general shrinking correctness.

## Frontend fixes

- An early property failure, discard, or exhaustion now cancels and settles open
  forks without replacing the original outcome with a malformed-property error.
  Root and branch failures shrink to `n = 5` and replay twice. Cleanup failures
  remain visible alongside the original failure. A normal return with an open
  fork still reports a malformed property.
- Bounded concurrent replication acquires native clones one batch at a time and
  closes each batch before acquiring the next. The cap now bounds live clones as
  well as active workers. Results retain input order, completed-worker diagnostics
  are retained, and cancellation prevents later batches from starting. Bounded
  child failures still shrink and replay.
- Replay envelopes decode the origin and blob from the right, so version strings
  containing colons and empty origins round-trip. UTF-8 and embedded-NUL origin
  bytes are preserved, and existing malformed-envelope checks still pass.
- A zero recursive leaf budget produces a stable, replayable validation failure.
  Previously, every attempted draw was rejected until the health check failed.
- Domain text limits default to 253 and accept only 4 through 253. Typed builders
  return validation failures for invalid limits; the direct API retains its error
  contract. The previous builder accepted a limit of 254.
- Floating-point builders reject positive-zero-to-negative-zero intervals and
  bounds that leave only a forbidden infinity before calling the engine. The
  signed-zero inversion previously produced an internal engine error. Tests cover
  binary32 and binary64, permitted infinity, and the valid interval from negative
  zero to positive zero.

## Release discovery

The old engine repository is archived. `scripts/update_engine.py` now discovers
stable `libhegel/<version>` releases in the
[engine monorepo](https://github.com/hegeldev/hegel/releases), skipping frontend
releases, drafts, and prereleases. Explicit legacy `libhegel-v*` tags remain
supported. The updater requires all supported assets and valid SHA-256 digests,
resolves annotated tags to a source commit, and provides `--dry-run` to inspect
the proposed lock without writing it. Seven isolated updater tests run in CI.

The live dry run selected
[libhegel 0.48.0](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.48.0)
at source `ef54eff1b95734b69e863fd2a595d5326cf547a6`. Main's engine lock and native
ABI are unchanged.

## Validation

The following checks pass locally on macOS ARM64:

```sh
lake build hegel_tests hegel_examples hegel_lean_examples hegel_maciver_tests hegel_panic_probe hegel_concurrency_tests hegel_adjacent_sweep
lake test
python3 scripts/check_ffi.py
python3 scripts/check_port.py
python3 scripts/test_elaboration.py
python3 scripts/test_safety.py
python3 scripts/test_concurrency.py
python3 scripts/test_downstream.py
python3 scripts/test_engine_update.py
```

This validates all **46** native signatures, **165** API targets across **29**
feature families, nine expected compiler rejections, panic handling, concurrency,
and a separate Lake consumer. Arbitrary derivation, proof-carrying shrinking,
property syntax, and imported test registration pass. Both example executables
pass; the deliberately failing example exits 1 and reports `n = 5`.

The supported Linux x86-64, Linux ARM64, and macOS ARM64 acceptance jobs are in the
[CI workflow](../.github/workflows/ci.yml). Hosted results for a published commit
must be checked separately from these local results.

## Engine candidate remains local

The local `codex/libhegel-0.48.0-candidate` branch at
`c04f09db6be52115219cd725bf64993dfef14e15` retains the earlier ABI migration and
includes these frontend fixes. Its lock records official digests for the header
and all supported archives; the macOS ARM64 downloads were hash-verified.
It builds, passes `lake test`, and passes all **48** candidate native signatures.
All **39** fixed-seed MacIver regressions pass; three of six separate discovery
probes miss a bug and remain recorded as misses. These are local macOS results;
the candidate has not been pushed, tagged, or tested by the three-platform matrix.

The unchanged `hegel_adjacent_sweep` driver uses 1,000 examples per seed, no
database, and two exact replays of every found counterexample. The
[complete receipt](adjacent-sweep-results-2026-10-26.json) records this run:

| Engine | Seeds | Minimal | Nonminimal | Discovery misses | Engine/replay errors | Exit |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Candidate 0.48.0 | 0–199 | 171 | 27 | 2 | 0 | 1 |

Every per-seed observation matches the October 19 run on 0.47.1. Seed 6 stops at
`(1549, 1548)` after 9,444 campaign evaluations; seeds 88 and 120 miss the failure.
Every found failure replays twice. The diagnostic fails despite the passing
fixed-seed suite. The
[current shrinker source](https://github.com/hegeldev/hegel/blob/ef54eff1b95734b69e863fd2a595d5326cf547a6/libhegel/src/native/shrinker/mod.rs)
retains the checkpoint-tracking path previously associated with nonminimal
shrinking. The [October 19 record](maintenance-2026-10-19.md) includes the retained
0.43.1 control; it was not rerun in this diagnostic campaign.

## API reference review

The reviewed reference head is `603eec1c70f4f6e1e445cdf0847c6723fd63997e`: 35
commits since the previous review and 58 since the original source pin. The
inventory still targets the original pinned API. This review led to the frontend
fixes above; it does not claim parity with every newer API extension.

Existing code already covers native signature guards, Unicode bounds and scalar
ranges, conflicting categories, rule-index failure identity, leading/trailing
trace elision, retained abort statistics, and explicit replay exhaustion. Lean's
natural-number journal depths, declaration-based test identities, flat database
keys, and per-worker journals avoid the corresponding reference issues.

Ordered weighted choice, unary floating-bound exclusivity modifiers, finite
enumeration metadata, and the existing defaults remain documented public
contracts. New engine error-kind APIs, stop-on-first-failure settings, profile and
Unicode-version settings, rejected-attempt pool restoration, and sequence
generators remain deferred extensions. They are not counted as implemented by
the pinned feature inventory. Release tags and unrelated branches are preserved.
