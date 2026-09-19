#!/usr/bin/env python3
"""Exercise compiler rejection paths for generator derivation and test registration."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
subprocess.run(['lake', 'build', 'Hegel'], cwd=ROOT,
               env=dict(os.environ, LAKE_RESTORE_ARTIFACTS='true'), check=True)
CASES = [
    ('indexed', '''inductive Indexed : Nat → Type where
  | zero : Indexed 0
  deriving Arbitrary
''', 'does not support indexed inductives'),
    ('mutual', '''mutual
inductive A where
  | leaf | node (b : B)
  deriving Arbitrary
inductive B where
  | node (a : A)
  deriving Arbitrary
end
''', 'does not support mutual inductives'),
    ('type_field', '''structure DynamicValue where
  ty : Type
  value : ty
  deriving Arbitrary
''', 'cannot generate a type-valued field'),
    ('missing_instance', '''opaque Custom : Type
structure Missing where
  value : Custom
  deriving Arbitrary
''', 'Arbitrary Custom'),
    ('bad_registration', '@[hegel_test] def wrong : Nat := 10\n',
     'requires Hegel.Test or Hegel.Property Unit'),
    ('bare_function', '@[hegel_test] def wrong (b : Bool) : Bool := b\n',
     'use property% to generate function arguments'),
    ('axiom_registration', '@[hegel_test] axiom missing : Property Unit\n',
     'requires an executable definition'),
    ('empty_suite', 'def empty : Array Test := hegel_suite% in Missing.Namespace\n',
     'found no registered tests'),
    ('proof_field', '''structure Uncheckable (p : Prop) where
  evidence : p
  deriving Arbitrary
''', 'Decidable'),
]
with tempfile.TemporaryDirectory(prefix='elaboration-', dir=ROOT / '.lake') as d:
    for name, code, expected in CASES:
        path = Path(d) / f'{name}.lean'
        path.write_text('import Hegel\nopen Hegel\n' + code)
        result = subprocess.run(['lake', 'env', 'lean', str(path)], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        if result.returncode == 0 or expected not in output:
            raise SystemExit(f'{name}: expected rejection containing {expected!r}\n{output}')
        print(f'ok: elaboration rejects {name}')
print(f'All {len(CASES)} compiler rejection checks passed.')
