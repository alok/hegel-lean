# October 19, 2026 maintenance

Main now uses **Lean 4.35.0**, the latest stable release reviewed on October 19.
The frontend and native bridge build without source changes. Libhegel stays pinned
to **0.43.1**: the new **0.47.1** candidate passes the fixed-seed acceptance suite,
but the wider shrinking diagnostic still fails. The retained engine also has this
defect; this decision does not establish that it is more correct than the candidate.

## Toolchain validation

The following checks pass on macOS ARM64 with Lean 4.35.0 and libhegel 0.43.1:

```sh
lake build hegel_tests hegel_examples hegel_lean_examples hegel_maciver_tests hegel_panic_probe hegel_concurrency_tests hegel_adjacent_sweep
lake test
python3 scripts/check_ffi.py
python3 scripts/check_port.py
python3 scripts/test_elaboration.py
python3 scripts/test_safety.py
python3 scripts/test_concurrency.py
python3 scripts/test_downstream.py
```

This covers all **46** Lean/C signatures, **165** API targets across **29** feature
families, nine expected compiler rejections, panic failure, concurrent workers,
and a separate Lake consumer. Derivation, proof-carrying generators, property
syntax, and imported test registration continue to pass. Both example executables
run successfully. All **39** fixed-seed MacIver regressions pass; four of six
separate discovery probes still miss a bug and remain recorded as misses.

The supported Linux x86-64, Linux ARM64, and macOS ARM64 acceptance jobs are in the
[CI workflow](../.github/workflows/ci.yml). The remote run for the published commit
must be checked separately from these local results.

## Latest engine candidate

[Libhegel 0.47.1](https://github.com/hegeldev/hegel-rust/releases/tag/libhegel-v0.47.1)
resolves to source `4ca447e14dbe5ac89f535ee4a8e810a1ce98fa24`. Changes since the previous
candidate include length-delimited ordinary strings, grammar generation and its
builder ABI, rejection and replay fixes, revised integer shrinking, and an optional
stop-on-first-failure setting. These changes were reviewed; the engine pin is not
advanced automatically.

The local `codex/libhegel-0.47.1-candidate` branch at `eeb3515` preserves the migration
from the previous 0.45.1 candidate. It records official release digests for all
supported archives and the header; the macOS ARM64 download was hash-verified.
The C wrappers use borrowed string views and copy returned strings with their byte
lengths. Owned generated strings use the matching upstream release function.
Empty, embedded-NUL, and multibyte regex patterns pass the existing candidate tests.

On Lean 4.35.0, the candidate builds, passes `lake test`, and passes all **48** native
signature checks. All **39** fixed-seed MacIver regressions now pass, including
adjacent UInt64 at seed 0, which failed on the previous candidate. Three of six
separate discovery probes miss a bug. This is local macOS validation only; the
candidate has not been pushed, tagged, or tested by the three-platform CI matrix.

## Wider diagnostic remains failing

The unchanged `hegel_adjacent_sweep` driver uses 1,000 examples per seed, no database,
and two exact replays of every found counterexample. The
[complete receipt](adjacent-sweep-results-2026-10-19.json) records both runs:

| Engine | Seeds | Minimal | Nonminimal | Discovery misses | Engine/replay errors | Exit |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Retained 0.43.1, compiler-update control | 0–8 | 8 | 1 | 0 | 0 | 1 |
| Candidate 0.47.1 | 0–199 | 171 | 27 | 2 | 0 | 1 |

The control reproduces the retained engine's seed-8 witness
`(137438952973, 137438952972)` after 8,134 campaign evaluations. Candidate seed 6
stops at `(1549, 1548)` after 9,444 evaluations; seeds 88 and 120 miss the failure.
Both found nonminimal witnesses replay twice. Neither diagnostic run passes, and
the different seed ranges must not be used as a quality comparison.

The [candidate shrinker source](https://github.com/hegeldev/hegel-rust/blob/4ca447e14dbe5ac89f535ee4a8e810a1ce98fa24/hegel-c/src/native/shrinker/mod.rs#L489-L540)
still clears changed-node tracking after a shape change without resetting the
checkpoint in that path. The wider results show nonminimal shrinking remains observable,
although the fixed-seed upgrade blocker from October 12 is no longer present.
The [earlier maintenance record](maintenance-2026-10-12.md) retains the 200-seed
results for 0.43.1 and 0.45.1 under Lean 4.34.1.

The reviewed API reference head is unchanged at
`9fdf9ef4af5810dbdc3e5475f5751a140157983b`. Its original source pin and intentional
frontend adaptations remain recorded in the port inventory. Release tags and
unrelated local branches are preserved.
