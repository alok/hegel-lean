# October 12, 2026 maintenance

Main retains Lean **4.34.1** and libhegel **0.43.1**. Libhegel **0.45.1** was evaluated
and remains deferred because it fails the unchanged adjacent-UInt64 regression at
seed 0. The retained engine also has the shrinking defect: its passing fixed seeds
must not be interpreted as general shrinking correctness.

## Wider Lean reproduction

The new [`Tests/AdjacentSweep.lean`](../Tests/AdjacentSweep.lean) diagnostic uses the
same filtered pair generator as the MacIver adjacent-UInt64 case, with 1,000 examples
per seed and no database. It requires `(0, 1)` or `(1, 0)` and replays every found
counterexample twice, checking its origin and annotations.

A local macOS ARM64 run with Lean 4.34.1, seeds **0–199**, produced:

| Engine | Minimal, replayed twice | Nonminimal, replayed twice | Discovery misses | Engine/replay errors |
| --- | ---: | ---: | ---: | ---: |
| Retained 0.43.1 | 167 | 29 | 4 | 0 |
| Candidate 0.45.1 | 172 | 24 | 4 | 0 |

Both processes exited **1**. Nonminimal witnesses and discovery misses are failures
of this diagnostic, never expected-success tests. The [complete per-seed receipt](adjacent-sweep-results-2026-10-12.json)
records every result. For example, retained 0.43.1 at seed 8 stopped at
`(137438952973, 137438952972)` after 8,134 campaign evaluations, then reproduced that
nonminimal counterexample twice. These finite samples do not establish which engine
has better shrinking quality in general.

```sh
lake exe hegel_adjacent_sweep       # seeds 0–199; currently exits 1
lake exe hegel_adjacent_sweep 9     # includes the retained engine's seed-8 failure
lake exe hegel_adjacent_sweep 1     # seed-0 control on retained 0.43.1
```

The original fixed-seed acceptance suite is unchanged. CI compiles the wider
diagnostic, while upgrade investigations run it explicitly. Its exit status,
discovery misses, and execution errors must remain visible when assessing an update.

## Defect attribution

The [October 5 follow-up](maintenance-2026-10-05.md#follow-up-root-cause-of-the-adjacent-uint64-failure)
records an earlier independent Rust investigation and its archived sweeps. Those
counts differ from this Lean reproduction; they are separate experiments with
different frontend span structures.

The [0.45.1 shrinker source](https://github.com/hegeldev/hegel-rust/blob/33d94c659e441127ce7b5a0f046ec4aa9315d794/hegel-c/src/native/shrinker/mod.rs#L493-L522)
still clears changed-node tracking when a deletion changes the choice sequence's
shape without resetting its checkpoint there. That is the mechanism identified by
the earlier local investigation. The local fix and regression tests have not become
part of the released engine. Retaining 0.43.1 preserves the current fixed-seed
acceptance result; it does not remove this defect.

## Candidate compatibility work

The local candidate is `faf1931` on `maintenance/libhegel-0.45.1-candidate`; it has not
been pushed or tagged. Its engine lock pins upstream source
`33d94c659e441127ce7b5a0f046ec4aa9315d794` and the official archive/header digests.
It carries the engine-owned capture, reliability-caveat, nondeterminism setting, and
bounded replay migration, plus the new regex ABI's explicit UTF-8 byte lengths.
Both regex wrappers pass empty, embedded-NUL, and multibyte literal pattern checks.

The candidate builds the test and example targets and passes all **48** native
signature checks. Its generator, reporting, stateful, safety, concurrency, replay,
and Lean integration groups pass. The MacIver group passes **38 of 39** regressions;
seed 0 again produces `(18446744073709551116, 18446744073709551117)` after 8,715
campaign evaluations. This failure keeps the dependency update out of main.
The earlier 0.44.1 candidate and all release tags are preserved.

## Main validation

The retained configuration passes the required build, `lake test`, native ABI,
API inventory, elaboration rejection, panic safety, concurrency watchdog, and
downstream Lake checks. The acceptance suite retains **39** passing MacIver
regression runs and **four misses among six discovery probes**, independently of
the broader diagnostic above. The [CI workflow](../.github/workflows/ci.yml) runs
the acceptance checks on Linux x86-64, Linux ARM64, and macOS ARM64.
