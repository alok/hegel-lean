#!/usr/bin/env python3
"""Check that the port inventory names real, imported Lean declarations."""
from pathlib import Path
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parent.parent
subprocess.run(['lake', 'build', 'Hegel'], cwd=ROOT,
               env=dict(os.environ, LAKE_RESTORE_ARTIFACTS='true'), check=True)
inventory = json.loads((ROOT / 'scripts/port-api.json').read_text())
targets = sorted({target for feature in inventory['features'] for target in feature['leanTargets']})
probe = ROOT / '.lake/PortInventory.lean'
probe.write_text('import Hegel\n' + '\n'.join(f'#check {target}' for target in targets) + '\n')
result = subprocess.run(['lake', 'env', 'lean', str(probe)], cwd=ROOT, capture_output=True, text=True)
if result.returncode:
    raise SystemExit(result.stdout + result.stderr)
pending = [feature['id'] for feature in inventory['features'] if feature['status'] != 'verified']
if pending:
    raise SystemExit('Inventory still has unverified features: ' + ', '.join(pending))
print(f'All {len(targets)} API targets exist across {len(inventory["features"])} verified feature families.')
