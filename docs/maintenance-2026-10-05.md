# October 5, 2026 maintenance

Main now uses Lean **4.34.1** and retains libhegel **0.43.1**. The native archive,
header digests, and source revision in `engine-lock.json` are unchanged. The
immutable v1.0.0 and v2.0.0 tags keep their original toolchain and engine pins.

## Engine upgrade decision

The libhegel **0.44.1** candidate at upstream commit
`ebfd9d53a3de91522e0c4e5941cf08242aba713b` was built with Lean 4.34.1 on macOS ARM64.
The frontend was adapted for the new captured-evidence, per-failure caveat, and
run-based replay APIs before running the suite. Those focused checks passed,
including nondeterministic graph replay and the 48 candidate FFI signatures.

The existing MacIver `adjacent-uint64` regression at seed **0** then failed in two
separate full-suite executions. Both produced:

```text
adjacent-uint64: unexpected witness (18446744073709551116, 18446744073709551117)
FAIL adjacent-uint64 (8715 evaluations)
Replay blob: AXicY2IAAi5OIMHz7z8YQLm8MC4As0wOMg==
```

The property draws two independent integers over `[0, 2^64 - 1]`, filters out equal
pairs, and fails when their absolute difference is at most one. The regression
requires the witness `(0, 1)` or `(1, 0)`. The candidate's blob reproduced the
nonminimal witness. This is an observed upgrade regression; its engine root cause
has not been established. The candidate was retained locally and was not published.

Restoring libhegel **0.43.1** under the same Lean **4.34.1** toolchain passes the
unchanged suite. In particular, adjacent-UInt64 seeds **0, 1, 42** all shrink to
`(0, 1)` and replay twice. The expected witnesses and seeds have not been weakened.
The engine update remains deferred until that regression is resolved.

## Follow-up: root cause of the adjacent-UInt64 failure

The later investigation found a shrinker defect that **0.43.1 also has**. The archived
October 5 pure-Rust reproduction of `adjacent-uint64` against hegel-rust (filtered pair,
seeds 0–199, no database) gives:

| Engine | Seeds ending at a nonminimal witness |
| --- | --- |
| 0.43.1 (`9a130bf`) | 49 / 200 |
| 0.44.1 (`ebfd9d5`) | 62 / 200 |
| 0.44.1 + local fix | 0 / 200 |

Seeds 0, 1, and 42 happen to pass on 0.43.1. The first bad commit for seed 0,
`d3bbb37d` ("Add a log-uniform float category over the range's binades"), does not touch
the shrinker. It adds a float weight that is sampled on every test case, which changes the
starting counterexample for seed 0.

Mechanism: after a deletion changes the choice sequence's length,
`Shrinker::update_change_tracking` clears the changed-node set but keeps the stale
checkpoint. Every later comparison is then also judged shape-changing, so the set stays empty and
`lower_common_node_offset` never fires. The two values are lowered one at a time until
the 500-shrink limit. The October 5 investigation left a 12-line fix locally that
rebaselines the checkpoint when the shape changes.

Keeping 0.43.1 is therefore not evidence that the older engine shrinks correctly. The
regression test passes there because of the seeds it uses.

The [October 12 record](maintenance-2026-10-12.md) independently rechecks the defect
through the Lean frontend and records the latest release candidate.

## Validation of main

The acceptance run on macOS ARM64 includes:

```sh
lake build hegel_tests hegel_examples hegel_lean_examples hegel_maciver_tests hegel_concurrency_tests hegel_panic_probe
lake test
python3 scripts/check_ffi.py
python3 scripts/check_port.py
python3 scripts/test_elaboration.py
python3 scripts/test_safety.py
python3 scripts/test_concurrency.py
python3 scripts/test_downstream.py
```

The MacIver suite passes all **39** regression runs. The six discovery probes retain
**four coverage misses**, reported as misses rather than evidence of complete discovery.
The [checked-in MacIver receipt](maciver-results.json) remains the historical Lean
4.34.0 snapshot; fresh receipts are generated at `.lake/maciver-results.json` and
uploaded by CI. Deriving, dependent proof fields, property syntax, imported test
registration, native linking, failure exit codes, and shrinking are also covered.

The [CI workflow](../.github/workflows/ci.yml) runs these checks on Linux x86-64,
Linux ARM64, and macOS ARM64 for the published commit.
