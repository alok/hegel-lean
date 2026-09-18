#!/usr/bin/env python3
"""Compile the C bridge against the prototypes emitted by this Lean toolchain."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
generated = (ROOT / '.lake/build/ir/Hegel/Internal/Raw.c').read_text()
prototypes = re.findall(r'^lean_object\* lean_hegel_\w+\([^;]*\);$', generated, re.M)
defined = set(re.findall(r'LEAN_EXPORT lean_obj_res (lean_hegel_\w+)\(',
                         (ROOT / 'c/hegel_lean.c').read_text()))
declared = set(re.findall(r'lean_hegel_\w+', '\n'.join(prototypes)))
if not declared or defined != declared:
    raise SystemExit(f'FFI symbol mismatch: missing={declared-defined}, extra={defined-declared}')
prefix = subprocess.check_output(['lean', '--print-prefix'], cwd=ROOT, text=True).strip()
with tempfile.TemporaryDirectory() as d:
    path = Path(d) / 'abi.c'
    path.write_text('#include <lean/lean.h>\n' + '\n'.join(prototypes)
                    + f'\n#include "{ROOT / "c/hegel_lean.c"}"\n')
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                    '-I', str(Path(prefix) / 'include'), '-I', str(ROOT / '.lake/hegel'),
                    str(path)], check=True)
print(f'All {len(declared)} Lean/C function signatures match.')
