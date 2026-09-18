#!/usr/bin/env python3
"""Refresh the engine lock from a release; build and test before committing it."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def api(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', help='libhegel release tag (defaults to the latest libhegel release)')
    args = parser.parse_args()
    repo = 'repos/hegeldev/hegel-rust'
    if args.tag:
        release = api(f'{repo}/releases/tags/{args.tag}')
    else:
        releases = api(f'{repo}/releases?per_page=100')
        release = next(r for r in releases if r['tag_name'].startswith('libhegel-v')
                       and not r['prerelease'] and not r['draft'])
    tag = release['tag_name']
    if not tag.startswith('libhegel-v'):
        raise SystemExit('Expected a libhegel release, not a Rust frontend release')
    old = json.loads((ROOT / 'engine-lock.json').read_text())
    assets = {a['name']: {'url': a['browser_download_url'],
                         'sha256': a['digest'].removeprefix('sha256:')}
              for a in release['assets'] if a['name'] in old['assets']}
    if set(assets) != set(old['assets']):
        raise SystemExit('Release is missing supported-platform assets')
    if any(len(a['sha256']) != 64 for a in assets.values()):
        raise SystemExit('Release is missing SHA-256 digests')
    ref = api(f'{repo}/git/ref/tags/{tag}')['object']
    while ref['type'] == 'tag':
        ref = api(f'{repo}/git/tags/{ref["sha"]}')['object']
    if ref['type'] != 'commit':
        raise SystemExit('Release tag does not resolve to a commit')
    lock = dict(old, version=tag.removeprefix('libhegel-v'), tag=tag,
                commit=ref['sha'], assets=assets)
    (ROOT / 'engine-lock.json').write_text(json.dumps(lock, indent=2) + '\n')
    print(f'Pinned {tag} at {ref["sha"]}. Run lake build, lake test, and scripts/check_ffi.py.')

if __name__ == '__main__':
    main()
