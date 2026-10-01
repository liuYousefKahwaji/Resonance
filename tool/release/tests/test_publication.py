import argparse
import base64
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release as r
import ci

SOURCE = 'a' * 40
OTHER = 'b' * 40
TREE = 'c' * 40


class PublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'publish'; self.output.mkdir()
        self.notes = '# Resonance 3.4.5\n\n- Smaller downloads.\n'
        notes_path = self.root / 'release/v3.4.5/patchnotes.md'
        notes_path.parent.mkdir(parents=True); notes_path.write_text(self.notes)
        files = {}
        for name, content in [('resonance-v3.4.5.apk', b'apk'), ('resonance-v3.4.5-windows.zip', b'zip'),
                              ('resonance-v3.4.5-windows.files.json', b'files')]:
            file = self.output / name; file.write_bytes(content); files[name] = r.asset(file)
        self.manifest = dict(schemaVersion=1, release=dict(version='3.4.5', buildNumber=12, tag='v3.4.5', notes=self.notes),
            android=dict(full=files['resonance-v3.4.5.apk'], deltas=[]),
            windows=dict(full=files['resonance-v3.4.5-windows.zip'], fileManifest=files['resonance-v3.4.5-windows.files.json'], deltas=[]))
        path = self.output / 'resonance-v3.4.5-update.json'; r.write_json(path, self.manifest)
        key = Ed25519PrivateKey.generate()
        seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        r.sign_manifest(path, base64.b64encode(seed).decode(), 'test')
        for mock in [patch.object(r, 'ROOT', self.root), patch.object(r, 'keys', return_value={'test': base64.b64encode(public).decode()}),
                     patch.object(r, 'pubspec', return_value=('3.4.5', 12)), patch.dict('os.environ', {'GITHUB_SHA': SOURCE})]:
            mock.start(); self.addCleanup(mock.stop)
        self.manifest, self.expected = r.verify_output(self.output)
        self.remote = None
        self.calls = []; self.uploads = []; self.tree = TREE
        mock = patch.object(r, 'api', side_effect=self.api); mock.start(); self.addCleanup(mock.stop)
        mock = patch.object(r.subprocess, 'run', side_effect=self.upload); mock.start(); self.addCleanup(mock.stop)
        self.args = argparse.Namespace(output=self.output, publish=True)

    def draft(self, names=None, source=SOURCE, draft=True):
        self.remote = dict(id=123, tag_name='v3.4.5', target_commitish=source, draft=draft, prerelease=False,
            html_url='https://github.com/example/release', assets=[])
        for name in self.expected if names is None else names:
            self.remote['assets'].append(dict(id=len(self.remote['assets'])+1, name=name,
                size=self.expected[name]['size'], digest='sha256:' + self.expected[name]['sha256'], state='uploaded'))

    def api(self, path, method='GET', data=None):
        self.calls.append((path, method, data))
        if method == 'POST':
            self.draft([]); self.remote.update(data); return copy.deepcopy(self.remote)
        if method == 'PATCH':
            r.checked_remote_assets(self.remote, self.expected)
            self.remote.update(data); return copy.deepcopy(self.remote)
        if path.startswith('/releases/tags/'): return None  # Reproduces the real draft 404.
        if path == '/releases/latest': return None
        if path.startswith('/releases?'): return [copy.deepcopy(self.remote)] if self.remote else []
        if path == '/releases/123': return copy.deepcopy(self.remote)
        if path.startswith('/git/commits/'): return dict(tree=dict(sha=self.tree if path.endswith(OTHER) else TREE))
        if path.startswith('/git/ref/tags/'): return None
        if path.startswith('/contents/'):
            text = self.notes if 'patchnotes.md' in path else 'version: 3.4.5+12\n'
            return dict(encoding='base64', content=base64.b64encode(text.encode()).decode())
        raise AssertionError('Unexpected API request: ' + path)

    def upload(self, command, **kwargs):
        self.assertEqual(command[:4], ['gh', 'release', 'upload', 'v3.4.5'])
        for file in command[4:command.index('--repo')]:
            name = Path(file).name; self.uploads.append(name)
            self.remote['assets'].append(dict(id=20+len(self.uploads), name=name, state='uploaded',
                size=self.expected[name]['size'], digest='sha256:' + self.expected[name]['sha256']))

    def mutations(self): return [call for call in self.calls if call[1] != 'GET']

    def test_new_draft_publishes_using_release_id_when_tag_endpoint_returns_404(self):
        r.publish(self.args)
        self.assertFalse(self.remote['draft'])
        self.assertEqual(set(self.uploads), set(self.expected))
        self.assertEqual([call[1] for call in self.mutations()], ['POST', 'PATCH'])
        self.assertEqual(self.remote['body'], self.notes)

    def test_resume_complete_draft_does_not_upload_or_recreate_assets(self):
        self.draft(); r.publish(self.args)
        self.assertFalse(self.remote['draft']); self.assertEqual(self.uploads, [])
        self.assertEqual([call[1] for call in self.mutations()], ['PATCH'])

    def test_resume_partial_draft_uploads_only_missing_assets(self):
        self.draft(['resonance-v3.4.5.apk']); r.publish(self.args)
        self.assertNotIn('resonance-v3.4.5.apk', self.uploads)
        self.assertEqual(len(self.uploads), 4); self.assertFalse(self.remote['draft'])

    def test_corrupt_existing_asset_stays_draft_without_clobber(self):
        self.draft(); self.remote['assets'][0]['digest'] = 'sha256:' + '0'*64
        with self.assertRaisesRegex(ValueError, 'identity mismatch'): r.publish(self.args)
        self.assertTrue(self.remote['draft']); self.assertEqual(self.mutations(), []); self.assertEqual(self.uploads, [])

    def test_unexpected_asset_stays_draft(self):
        self.draft(); self.remote['assets'].append(dict(name='surprise.exe'))
        with self.assertRaisesRegex(ValueError, 'Unexpected'): r.publish(self.args)
        self.assertEqual(self.mutations(), [])

    def test_another_source_tree_stays_draft(self):
        self.draft(source=OTHER); self.tree = 'd'*40
        with self.assertRaisesRegex(ValueError, 'different source tree'): r.publish(self.args)
        self.assertEqual(self.mutations(), [])

    def test_empty_commit_with_same_source_tree_can_resume_draft(self):
        self.draft(source=OTHER); r.publish(self.args)
        self.assertFalse(self.remote['draft'])

    def test_exact_published_release_is_not_modified_on_retry(self):
        self.draft(draft=False); r.publish(self.args)
        self.assertEqual(self.mutations(), []); self.assertEqual(self.uploads, [])

    def test_published_release_with_different_assets_is_never_overwritten(self):
        self.draft(draft=False); self.remote['assets'][0]['size'] += 1
        self.assertRaises(ValueError, r.publish, self.args)
        self.assertEqual(self.mutations(), [])

    def test_bad_signature_rejected_before_remote_mutation(self):
        (self.output/'resonance-v3.4.5-update.json').write_bytes(b'changed')
        self.assertRaises(Exception, r.publish, self.args)
        self.assertEqual(self.calls, [])

    def test_changed_patch_notes_rejected_before_remote_mutation(self):
        (self.root/'release/v3.4.5/patchnotes.md').write_text('Changed notes')
        self.assertRaises(ValueError, r.publish, self.args); self.assertEqual(self.calls, [])

    def test_build_number_mismatch_rejected_before_remote_mutation(self):
        with patch.object(r, 'pubspec', return_value=('3.4.5', 13)):
            self.assertRaises(ValueError, r.publish, self.args)
        self.assertEqual(self.calls, [])

    def test_newer_latest_release_prevents_stale_draft_publication(self):
        self.draft(); original = self.api
        with patch.object(r, 'api', side_effect=lambda path, **kw: {'tag_name': 'v3.4.6'}
                if path == '/releases/latest' else original(path, **kw)):
            with self.assertRaisesRegex(ValueError, 'same/newer'): r.publish(self.args)
        self.assertTrue(self.remote['draft']); self.assertEqual(self.mutations(), [])

    def test_missing_release_id_response_keeps_draft(self):
        self.draft()
        with patch.object(r, 'api', return_value=None):
            with self.assertRaisesRegex(ValueError, 'metadata unavailable'):
                r.finish_publication(self.remote, self.manifest, self.expected)
        self.assertTrue(self.remote['draft'])

    def test_orphan_tag_is_not_overwritten(self):
        original = self.api
        with patch.object(r, 'api', side_effect=lambda path, **kw: {'object': {}} if path.startswith('/git/ref/tags/') else original(path, **kw)):
            with self.assertRaisesRegex(ValueError, 'Orphan'): r.publish(self.args)
        self.assertEqual(self.mutations(), [])

    def test_recovery_checks_fully_uploaded_assets_without_downloading_binaries(self):
        self.draft()
        run = dict(head_sha=SOURCE)
        with patch.object(ci, 'verified_run', return_value=run), patch.object(ci, 'small_asset',
                side_effect=lambda entry: (self.output/entry['name']).read_bytes()) as download:
            ci.recover(argparse.Namespace(run_id=456, publish=False))
            self.assertEqual(download.call_count, 2)
            self.assertEqual(self.mutations(), [])
            ci.recover(argparse.Namespace(run_id=456, publish=True))
        self.assertFalse(self.remote['draft']); self.assertEqual(self.uploads, [])


class RunReuseTests(unittest.TestCase):
    def setUp(self):
        self.run = dict(id=123, path='.github/workflows/release.yml', head_sha=SOURCE, head_branch='main',
            head_repository=dict(full_name=r.REPO), event='push', status='completed', conclusion='failure',
            head_commit=dict(tree_id=TREE))
        self.states = {name: 'success' for name in ('detect', 'windows', 'android', 'prepare')}
        self.expired = False

    def api(self, path):
        if path.startswith('/git/commits/'): return dict(tree=dict(sha=TREE))
        if path.startswith('/actions/workflows/'): return dict(workflow_runs=[self.run])
        if path == '/actions/runs/123': return self.run
        if '/jobs?' in path: return dict(jobs=[dict(name=name, conclusion=state) for name, state in self.states.items()])
        if '/artifacts?' in path: return dict(artifacts=[dict(name='verified-release-3.4.5', expired=self.expired)])
        raise AssertionError(path)

    def test_failed_publish_can_reuse_successful_preparation(self):
        with patch.object(r, 'api', side_effect=self.api):
            self.assertEqual(ci.reusable_run('3.4.5', SOURCE)['id'], 123)

    def test_changed_source_tree_requires_rebuild(self):
        self.run['head_commit']['tree_id'] = 'd'*40
        with patch.object(r, 'api', side_effect=self.api): self.assertIsNone(ci.reusable_run('3.4.5', SOURCE))

    def test_failed_preparation_and_expired_artifacts_are_not_reused(self):
        with patch.object(r, 'api', side_effect=self.api):
            self.states['prepare'] = 'failure'; self.assertIsNone(ci.reusable_run('3.4.5', SOURCE))
            self.states['prepare'] = 'success'; self.expired = True
            self.assertIsNone(ci.reusable_run('3.4.5', SOURCE))

    def test_other_repository_branch_and_workflow_are_rejected(self):
        for key, value in [('head_branch', 'untrusted'), ('path', 'another.yml'),
                           ('head_repository', dict(full_name='another/repository'))]:
            with self.subTest(key=key), patch.dict(self.run, {key: value}), patch.object(r, 'api', side_effect=self.api):
                self.assertIsNone(ci.reusable_run('3.4.5', SOURCE))


if __name__ == '__main__': unittest.main()
