#!/usr/bin/env python3
"""Run concurrency regressions with an external watchdog for cancellation deadlocks."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
executable = root / ".lake/build/bin/hegel_concurrency_tests"
if not executable.is_file():
    sys.exit("Build hegel_concurrency_tests before running the concurrency watchdog")
try:
    subprocess.run([str(executable)], cwd=root, check=True, timeout=45)
except subprocess.TimeoutExpired:
    sys.exit("Concurrency regressions timed out after 45 seconds; a worker may not have settled")
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
