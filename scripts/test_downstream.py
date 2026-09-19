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
@[default_target, test_driver]
lean_exe consumer where
  root := `Main
lean_lib Consumer
''')
    (dest / 'Consumer').mkdir()
    (dest / 'Consumer/Properties.lean').write_text('''import Hegel
open Hegel Hegel.Property
namespace Consumer
structure Packet where
  n : Nat
  value : Fin (n + 1)
  valid : value.val ≤ n
  deriving Repr, Arbitrary
@[hegel_test] def derived : Property Unit :=
  property% (fun p : Packet => decide (p.value.val ≤ p.n))
@[hegel_test] def reverseTwice : Property Unit :=
  property% (fun xs : List Nat => xs.reverse.reverse == xs)
@[hegel_test] def native : Property Unit := do
  let n ← forAll (Gen.int 0 100)
  assertProp! (n ≥ 0)
  let pool ← Pool.named "consumer values"
  pool.add n
  assertEq! (← draw pool.reuse) n
  let date ← draw (Gen.date ⟨2024, 2, 29⟩ ⟨2024, 2, 29⟩)
  assert! date.valid
  let pair ← Property.Branch.concurrently (pure (1 : Nat)) (pure (2 : Nat))
  assertEq! pair (1, 2)
end Consumer
''')
    (dest / 'Main.lean').write_text('''import Consumer.Properties
open Hegel
def main (args : List String) : IO UInt32 := do
  if args.contains "fail" then
    runTests #[{ name := "deliberate generated failure"
                 property := property% (fun n : Nat => decide (n < 5))
                 settings := { database := none, seed := some 42 } }]
  else
    let tests : Array Test := hegel_suite% in Consumer
    runTests (tests.map fun t => { t with
      settings := { database := none, seed := some 42, maxExamples := 10 } })
''')
    subprocess.run(['lake', 'build'], cwd=dest, check=True)
    subprocess.run(['lake', 'test'], cwd=dest, check=True)
    failure = subprocess.run(['lake', 'exe', 'consumer', 'fail'], cwd=dest,
                             capture_output=True, text=True, timeout=60)
    if failure.returncode != 1 or 'Draw 1: 5' not in failure.stdout + failure.stderr:
        raise SystemExit('Downstream generated failure did not shrink and exit 1:\n' +
                         failure.stdout + failure.stderr)
    print('Downstream derivation, imported registration, lake test, and failure exit code passed.')
