#!/usr/bin/env python3
"""Require unchecked Lean panics to fail the process instead of returning a false pass."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
subprocess.run(['lake', 'build', 'hegel_panic_probe'], cwd=ROOT, check=True)
result = subprocess.run([str(ROOT / '.lake/build/bin/hegel_panic_probe')], cwd=ROOT,
                        capture_output=True, text=True, timeout=30)
if result.returncode == 0 or 'PASS panic-must-not-pass' in result.stdout:
    raise SystemExit(f'Unchecked Lean panic incorrectly passed:\n{result.stdout}\n{result.stderr}')
if 'PANIC' not in result.stdout + result.stderr:
    raise SystemExit(f'Probe failed for an unexpected reason:\n{result.stdout}\n{result.stderr}')
print(f'Unchecked Lean panic correctly terminated the process (exit {result.returncode}).')
