#!/usr/bin/env python3
"""Compile the C bridge against the prototypes emitted by this Lean toolchain."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
modules = sorted((ROOT / 'Hegel/Internal').glob('*.lean'))
# Cached executables need not restore intermediate artifacts in recent Lake versions.
subprocess.run(['lake', 'build', *[f'Hegel.Internal.{p.stem}:c' for p in modules]],
               cwd=ROOT, env=dict(os.environ, LAKE_RESTORE_ARTIFACTS='true'), check=True)
generated = '\n'.join((ROOT / f'.lake/build/ir/Hegel/Internal/{p.stem}.c').read_text()
                      for p in modules)
bridges = sorted((ROOT / 'c').glob('*.c'))
prototypes = re.findall(r'^lean_object\* lean_hegel_\w+\([^;]*\);$', generated, re.M)
defined = set(re.findall(r'LEAN_EXPORT lean_obj_res (lean_hegel_\w+)\(',
                         '\n'.join(p.read_text() for p in bridges)))
declared = set(re.findall(r'lean_hegel_\w+', '\n'.join(prototypes)))
if not declared or defined != declared:
    raise SystemExit(f'FFI symbol mismatch: missing={declared-defined}, extra={defined-declared}')
prefix = subprocess.check_output(['lean', '--print-prefix'], cwd=ROOT, text=True).strip()
with tempfile.TemporaryDirectory() as d:
    for bridge in bridges:
        path = Path(d) / bridge.name
        path.write_text('#include <lean/lean.h>\n' + '\n'.join(set(prototypes))
                        + f'\n#include "{bridge}"\n')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                        '-I', str(Path(prefix) / 'include'), '-I', str(ROOT / '.lake/hegel'),
                        str(path)], check=True)
print(f'All {len(declared)} Lean/C function signatures match.')
