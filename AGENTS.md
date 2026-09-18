# Development

- Read README.md and engine-lock.json before changing the engine integration.
- Keep Lean's native C signatures synchronized with Hegel/Internal/Raw.lean.
- Do not count engine errors, rejection exhaustion, or flaky replay as successful tests.
- Preserve stable failure origins and byte lengths (strings can contain embedded NULs).
- Every native handle needs its matching upstream release function on success and error paths.
- After a behavior change, run `lake build hegel_tests hegel_examples`, `lake test`,
  `python3 scripts/check_ffi.py`, and `python3 scripts/test_downstream.py`.
- Update pinned dependencies deliberately and validate all supported CI platforms.
- Main is the development branch; direct commits are authorized by the repository owner.
- Do not add test databases, downloaded binaries, or local environment files to Git.
