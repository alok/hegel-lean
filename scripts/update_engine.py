#!/usr/bin/env python3
"""Refresh the engine lock from a release; build and test before committing it."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
CURRENT_REPOSITORY = 'hegeldev/hegel'
LEGACY_REPOSITORY = 'hegeldev/hegel-rust'


def api(endpoint):
    return json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True))


def resolve_lock(old, tag=None):
    repository = LEGACY_REPOSITORY if tag and tag.startswith('libhegel-v') else CURRENT_REPOSITORY
    prefix = 'libhegel-v' if repository == LEGACY_REPOSITORY else 'libhegel/'
    repo = f'repos/{repository}'
    if tag:
        if not re.fullmatch(re.escape(prefix) + r'\d+\.\d+\.\d+', tag):
            raise SystemExit('Expected a stable libhegel release tag')
        release = api(f'{repo}/releases/tags/{quote(tag, safe="")}')
    else:
        releases = api(f'{repo}/releases?per_page=100')
        release = next((r for r in releases
                        if re.fullmatch(re.escape(prefix) + r'\d+\.\d+\.\d+', r['tag_name'])
                        and not r['prerelease'] and not r['draft']), None)
        if release is None:
            raise SystemExit('No stable libhegel release found')
    tag = release['tag_name']
    if not re.fullmatch(re.escape(prefix) + r'\d+\.\d+\.\d+', tag):
        raise SystemExit('Expected a stable libhegel release tag')
    if release['prerelease'] or release['draft']:
        raise SystemExit('Expected a published stable libhegel release')
    assets = {}
    for asset in release['assets']:
        if asset['name'] not in old['assets']:
            continue
        digest = asset.get('digest')
        if not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
            raise SystemExit('Release is missing valid SHA-256 digests')
        assets[asset['name']] = {'url': asset['browser_download_url'],
                                 'sha256': digest.removeprefix('sha256:').lower()}
    if set(assets) != set(old['assets']):
        raise SystemExit('Release is missing supported-platform assets')
    ref = api(f'{repo}/git/ref/tags/{quote(tag, safe="")}')['object']
    while ref['type'] == 'tag':
        ref = api(f'{repo}/git/tags/{ref["sha"]}')['object']
    if ref['type'] != 'commit':
        raise SystemExit('Release tag does not resolve to a commit')
    return dict(old, version=tag.removeprefix(prefix), tag=tag,
                repository=f'https://github.com/{repository}', commit=ref['sha'], assets=assets)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', help='libhegel/<version>, or legacy libhegel-v<version>')
    parser.add_argument('--dry-run', action='store_true', help='Print the proposed lock without writing it')
    args = parser.parse_args()
    lock = resolve_lock(json.loads((ROOT / 'engine-lock.json').read_text()), args.tag)
    encoded = json.dumps(lock, indent=2) + '\n'
    if args.dry_run:
        print(encoded, end='')
    else:
        (ROOT / 'engine-lock.json').write_text(encoded)
        print(f'Pinned {lock["tag"]} at {lock["commit"]}. '
              'Run lake build, lake test, and scripts/check_ffi.py.')


if __name__ == '__main__':
    main()
