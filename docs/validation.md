# Version 1 validation

The v1 frontend is checked against libhegel **0.43.1** at
[`9a130bf`](https://github.com/hegeldev/hegel-rust/tree/9a130bfde99005504b0004428e047803ac18d3a0),
with Lean **4.34.0**. The [port inventory](../scripts/port-api.json) records the pinned frontend
reference, 29 feature families, their Lean declarations, and their regression suites.

`check_port.py` asks Lean to resolve all **165 public targets**. `check_ffi.py` compiles every
native bridge translation unit against all **46 signatures** emitted by this Lean compiler.
Both scripts explicitly restore intermediate artifacts when Lake serves cached builds.
These checks establish API presence and ABI agreement; they do not prove semantic equivalence.

## Executed suites

The following passed on Apple Silicon macOS before publication. The
[CI workflow](../.github/workflows/ci.yml) repeats verification on macOS ARM64, Linux x86-64,
and Linux ARM64.

| Suite | Checks |
| --- | --- |
| Core integration | Bounds, Unicode/NUL, large integers, dependent generators, shrinking minima, multiple failure origins, database reuse, IO failure, health checks, native lifecycle |
| Generators | 45 named checks: 29 valid campaigns, five shrinking cases with two replays each, eleven invalid configurations with replay |
| Reporting | Seven groups covering settings, diffs, source identities, replay divergence, cleanup, pool provenance, invariant boundaries, and rendering |
| Stateful and pools | 21 checks including exact pool-event replay, rejected rules, invariants, actual worker overlap, group isolation, and shared pools |
| Forks and branches | 27 checks including repeated joins, ignored forks, nested cancellation, bounded scheduling, cleanup errors, and control-flow precedence |
| Runner safety | Empty/rejected campaigns, 1,200 caught span aborts, a 1,500-element flat vector, cleanup failure, unique cardinality, and sampling contracts |
| Replay tokens | Portable UTF-8/NUL envelope, malformed input categories, version mismatch, stable origin, and exact reconstructed observations |
| MacIver scenarios | 39 regression runs across three seeds, plus six discovery probes that retain coverage misses |

Commands:

```sh
lake build hegel_tests hegel_examples hegel_concurrency_tests hegel_panic_probe
lake test
python3 scripts/check_ffi.py
python3 scripts/check_port.py
python3 scripts/test_safety.py
python3 scripts/test_concurrency.py
python3 scripts/test_downstream.py
```

The concurrency watchdog terminates a hung regression process after 45 seconds. The panic probe
runs separately and must exit unsuccessfully after an unchecked array/list index. The downstream
check creates another Lake package and exercises ordinary generators, source assertions, pools,
native dates, and concurrent branches using inherited native link dependencies.

## Audit fixes

The implementation and regression suite address these concrete failure modes:

- Unchecked Lean panics could return a default value and falsely pass. Campaign startup now enables
  the runtime's process-wide fatal-panic policy; ordinary assertion failures remain shrinkable.
- Exhausted rejection and phases with no executions could be reported as passes. Such campaigns
  now return an error.
- Locally caught generator exceptions left native spans open. Bracketed spans restore state, while
  native recursive retry signals retain the engine's required handling.
- Flat collection loops accumulated nested bind spans. Internal iteration now keeps constant span
  depth, verified with a 1,500-element vector.
- Fixed-size uniqueness needed native variable-size mode for rejected duplicates. Collections
  use the required overshoot mode and trim according to their container's ordering.
- Native clone overrun/discard signals were incorrectly classified as engine errors. Their control
  meanings now survive worker acquisition.
- Cancellation stopped at nested joins. It now propagates to descendants, including persistent
  worker rounds; unstarted bounded branches release their clones without executing their bodies.
- Cancelled workers lost cleanup errors. Explicit and implicit cancellation now retain each
  cleanup diagnostic exactly once.
- Replay evidence could be marked reconstructed after divergence. Reports now preserve precise
  divergence reasons and skip later reconstruction when cleanup or execution aborts it.
- Joined invariant failures inherited the previous worker's step. Round boundaries now create
  their own trace step, and drawn pool values retain source/transfer provenance.

`clang --analyze` also completed without diagnostics on all four bridge translation units.
The engine, compiler/runtime, C ownership code, and actual thread interleavings remain outside
Lean's logical verification. Passing tests do not establish universal correctness or identical
seeded traces across language frontends.
