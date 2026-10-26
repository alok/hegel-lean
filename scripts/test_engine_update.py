#!/usr/bin/env python3
"""Exercise release discovery and lock integrity without changing the installed pin."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import update_engine

NAMES = ['hegel.h', 'libhegel-darwin-arm64.a', 'libhegel-linux-amd64.a', 'libhegel-linux-arm64.a']
OLD = {'repository': 'https://github.com/hegeldev/hegel-rust', 'version': '0.43.1',
       'tag': 'libhegel-v0.43.1', 'commit': 'a' * 40,
       'assets': {name: {} for name in NAMES}}


def release(tag='libhegel/0.48.0'):
    return {'tag_name': tag, 'draft': False, 'prerelease': False,
            'assets': [{'name': name, 'digest': 'sha256:' + 'b' * 64,
                        'browser_download_url': 'https://example.invalid/' + name} for name in NAMES]}


class EngineUpdateTests(unittest.TestCase):
    def test_monorepo_discovery_skips_frontends_and_prereleases(self):
        releases = [release('frontends/ocaml/9.0.0'),
                    dict(release('libhegel/0.50.0'), prerelease=True),
                    dict(release('libhegel/0.49.0'), draft=True), release()]
        with patch.object(update_engine, 'api', side_effect=[releases,
                {'object': {'type': 'tag', 'sha': 'tag-object'}},
                {'object': {'type': 'commit', 'sha': 'c' * 40}}]) as api:
            lock = update_engine.resolve_lock(OLD)
        self.assertEqual(lock['repository'], 'https://github.com/hegeldev/hegel')
        self.assertEqual((lock['version'], lock['tag'], lock['commit']),
                         ('0.48.0', 'libhegel/0.48.0', 'c' * 40))
        self.assertEqual(set(lock['assets']), set(NAMES))
        self.assertEqual(api.call_args_list[0].args[0], 'repos/hegeldev/hegel/releases?per_page=100')
        self.assertIn('libhegel%2F0.48.0', api.call_args_list[1].args[0])
        self.assertEqual(OLD['version'], '0.43.1')

    def test_explicit_legacy_tag_remains_supported(self):
        with patch.object(update_engine, 'api', side_effect=[release('libhegel-v0.43.1'),
                {'object': {'type': 'commit', 'sha': 'a' * 40}}]) as api:
            lock = update_engine.resolve_lock(OLD, 'libhegel-v0.43.1')
        self.assertEqual(lock['repository'], OLD['repository'])
        self.assertEqual(lock['version'], '0.43.1')
        self.assertTrue(api.call_args_list[0].args[0].startswith('repos/hegeldev/hegel-rust/'))

    def test_rejects_incomplete_platform_assets(self):
        candidate = release()
        candidate['assets'].pop()
        with patch.object(update_engine, 'api', return_value=candidate):
            with self.assertRaisesRegex(SystemExit, 'supported-platform assets'):
                update_engine.resolve_lock(OLD, candidate['tag_name'])

    def test_rejects_missing_or_nonhex_digests(self):
        for digest in (None, '', 'sha256:' + 'z' * 64, 'sha256:abc'):
            with self.subTest(digest=digest):
                candidate = release()
                candidate['assets'][0]['digest'] = digest
                with patch.object(update_engine, 'api', return_value=candidate):
                    with self.assertRaisesRegex(SystemExit, 'SHA-256'):
                        update_engine.resolve_lock(OLD, candidate['tag_name'])

    def test_rejects_wrong_release_family_and_unpublished_tags(self):
        with patch.object(update_engine, 'api') as api:
            with self.assertRaisesRegex(SystemExit, 'stable libhegel'):
                update_engine.resolve_lock(OLD, 'frontends/rust/1.0.0')
            api.assert_not_called()
        with patch.object(update_engine, 'api', return_value=dict(release(), draft=True)):
            with self.assertRaisesRegex(SystemExit, 'published stable'):
                update_engine.resolve_lock(OLD, 'libhegel/0.48.0')
        with patch.object(update_engine, 'api', return_value=[]):
            with self.assertRaisesRegex(SystemExit, 'No stable'):
                update_engine.resolve_lock(OLD)

    def test_rejects_noncommit_tag_target(self):
        with patch.object(update_engine, 'api', side_effect=[release(),
                {'object': {'type': 'tree', 'sha': 'd' * 40}}]):
            with self.assertRaisesRegex(SystemExit, 'resolve to a commit'):
                update_engine.resolve_lock(OLD, 'libhegel/0.48.0')

    def test_dry_run_does_not_change_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'engine-lock.json'
            original = json.dumps(OLD)
            path.write_text(original)
            proposed = copy.deepcopy(OLD)
            proposed['version'] = '0.48.0'
            output = io.StringIO()
            with patch.object(update_engine, 'ROOT', Path(directory)), \
                 patch.object(update_engine, 'resolve_lock', return_value=proposed), \
                 patch('sys.argv', ['update_engine.py', '--dry-run']), \
                 contextlib.redirect_stdout(output):
                update_engine.main()
            self.assertEqual(path.read_text(), original)
            self.assertEqual(json.loads(output.getvalue())['version'], '0.48.0')


if __name__ == '__main__':
    unittest.main()
