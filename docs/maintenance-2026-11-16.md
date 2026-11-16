# November 16, 2026 maintenance

Main now uses [Lean 4.36.0](https://github.com/leanprover/lean4/releases/tag/v4.36.0).
The existing Lean and native sources built with the new compiler. The local macOS
ARM64 checks covered all 165 port inventory targets, 46 native signatures, nine
compiler rejection tests, the panic and concurrency checks, the examples, and a
separate Lake consumer. The consumer derived a generator for dependent fields,
imported registered properties, and shrank a deliberately failing property to 5.
The reference head reviewed on November 9 is still `603eec1`.

## Engine decision

Main uses libhegel 0.43.1. The local branch `codex/libhegel-0.51.6-candidate`
at `48fd67455c751dc03598df5eae3c5cc0ca1efb71` tests [libhegel 0.51.6](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.51.6)
at `a6928220ae21e2658994a9246b93f84f21557447` on the same toolchain. Its lock
records the header and all three archive digests. The candidate passed the macOS
ARM64 compatibility suite, including 48 native signatures.

Both engines passed all 39 fixed MacIver regressions. The wider adjacent-UInt64
diagnostic ran seeds 0–199 at 1,000 examples per seed and exited 1 on both engines.
Every counterexample found replayed twice with the same origin and annotations.

| libhegel | Minimal | Nonminimal | Missed | Engine or replay errors |
| --- | ---: | ---: | ---: | ---: |
| 0.43.1 | 167 | 29 | 4 | 0 |
| 0.51.6 | 171 | 27 | 2 | 0 |

The candidate found four more minima in aggregate, but missed seeds 88 and 120.
The published engine found and shrank both to `(0, 1)`. With the same case budget,
0.51.6 still stops at `(1549, 1548)` on seed 6. Given the mixed shrinking results
and the version check on stored replay tokens, this update adopts only the compiler.

Run `lake exe hegel_adjacent_sweep` in either checkout to reproduce the diagnostic.
All 200 rows for 0.43.1 matched the [October 12 baseline](adjacent-sweep-results-2026-10-12.json)
and all 200 rows for 0.51.6 matched the [November 9 candidate](adjacent-sweep-results-2026-11-09.json),
including witnesses, evaluation counts and replay counts.

## Single-case workload reporting

[Libhegel 0.51.1](https://github.com/hegeldev/hegel/releases/tag/libhegel%2F0.51.1)
introduced a mode that runs one example without recording choices when
`ANTITHESIS_OUTPUT_DIR` is set and the database is disabled. A failing property
then has neither a capture stamp nor a replay blob. In a downstream executable
with that environment, the previous bridge reported a missing-evidence error and
lost the assertion message. The candidate now checks the single execution's
status and origin against the engine result and returns the original failure,
annotations and observed evidence. The regression runs against a temporary local
output directory.
