#!/usr/bin/env python3
"""Fetch the pinned release artifacts; verify every byte against engine-lock.json."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def main():
    lock = json.loads((ROOT / 'engine-lock.json').read_text())
    system = {'Darwin': 'darwin', 'Linux': 'linux'}.get(platform.system())
    arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'amd64'}.get(platform.machine())
    artifact = f'libhegel-{system}-{arch}.a'
    if artifact not in lock['assets']:
        raise SystemExit(f'Unsupported platform: {platform.system()}/{platform.machine()}')
    dest = ROOT / '.lake' / 'hegel'
    dest.mkdir(parents=True, exist_ok=True)
    for name, output in [(artifact, 'libhegel.a'), ('hegel.h', 'hegel.h')]:
        spec = lock['assets'][name]
        path = dest / output
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == spec['sha256']:
            continue
        print(f'Downloading {name} ({lock["version"]})', flush=True)
        fd, tmp = tempfile.mkstemp(dir=dest)
        os.close(fd)
        try:
            subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--silent',
                            '--show-error', '--output', tmp, spec['url']], check=True)
            if hashlib.sha256(Path(tmp).read_bytes()).hexdigest() != spec['sha256']:
                raise SystemExit(f'SHA-256 mismatch for {name}')
            os.replace(tmp, path)
        finally:
            Path(tmp).unlink(missing_ok=True)

if __name__ == '__main__':
    main()
