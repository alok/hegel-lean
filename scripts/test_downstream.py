#!/usr/bin/env python3
"""Check that an ordinary Lake consumer inherits the native link dependencies."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='hegel-consumer-') as d:
    dest = Path(d)
    (dest / 'lean-toolchain').write_text((ROOT / 'lean-toolchain').read_text())
    (dest / 'lakefile.lean').write_text('''import Lake
open Lake DSL
package consumer
require «hegel-lean» from ''' + json.dumps(str(ROOT)) + '''
@[default_target]
lean_exe consumer where
  root := `Main
''')
    (dest / 'Main.lean').write_text('''import Hegel
open Hegel Hegel.Property
def main : IO Unit := check! "consumer" (do
  let n ← forAll (Gen.int 0 100)
  assertProp (n ≥ 0) "nonnegative") { database := none }
''')
    subprocess.run(['lake', 'build'], cwd=dest, check=True)
    subprocess.run(['lake', 'exe', 'consumer'], cwd=dest, check=True)
