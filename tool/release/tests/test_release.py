import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from zipfile import ZipFile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'release.py')
r = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(r)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = self.root / 'old'; self.new = self.root / 'new'
        self.old.mkdir(); self.new.mkdir()
        for root, values in [(self.old, {'resonance.exe': b'old', 'same.dll': b'unchanged', 'obsolete.dll': b'remove'}),
                             (self.new, {'resonance.exe': b'new', 'same.dll': b'unchanged', 'added.dll': b'add'})]:
            for name, data in values.items(): (root / name).write_bytes(data)
        self.source = r.file_manifest(self.old, '3.4.5')
        self.target = r.file_manifest(self.new, '3.4.7')
        r.write_json(self.old / 'resonance-install.json', self.source)
        r.write_json(self.new / 'resonance-install.json', self.target)
        self.old_zip = self.root / 'old.zip'; self.delta_zip = self.root / 'delta.zip'
        r.zip_tree(self.old, self.old_zip)
        self.metadata = r.windows_delta(self.old_zip, self.new, '3.4.7', self.delta_zip)

    def test_versions(self):
        for text in ['v3.4.5', '3.4.5', 'v.3.4.5']: self.assertEqual(r.version(text), (3, 4, 5))
        for text in ['v3.4.5-beta', '3.4', '3.4.5;rm']: self.assertRaises(ValueError, r.version, text)

    def test_unicode_paths_use_same_order_as_dart_and_powershell(self):
        (self.new/'\U0001f600.dll').write_bytes(b'emoji')
        (self.new/'\ue000.dll').write_bytes(b'bmp')
        manifest = r.file_manifest(self.new, '3.4.7')
        self.assertEqual([f['path'] for f in manifest['files']][-2:], ['\U0001f600.dll', '\ue000.dll'])
        r.verify_tree(self.new, manifest)

    def test_direct_patch_changes_additions_and_deletions(self):
        with ZipFile(self.delta_zip) as z:
            metadata = json.loads(z.read('delta.json'))
            self.assertEqual({f['path'] for f in metadata['changed']}, {'resonance.exe', 'added.dll'})
            self.assertEqual(metadata['deleted'], ['obsolete.dll'])
            self.assertNotIn('payload/same.dll', z.namelist())
        self.assertEqual(self.metadata['fromVersion'], '3.4.5')
        self.assertEqual(self.metadata['targetTreeSha256'], self.target['treeSha256'])

    def test_legacy_has_no_delta(self):
        (self.old / 'resonance-install.json').unlink(); r.zip_tree(self.old, self.old_zip)
        self.assertIsNone(r.windows_delta(self.old_zip, self.new, '3.4.7', self.delta_zip))

    def test_corrupt_source_and_case_collisions_rejected(self):
        (self.old / 'same.dll').write_bytes(b'changed'); r.zip_tree(self.old, self.old_zip)
        self.assertRaises(ValueError, r.windows_delta, self.old_zip, self.new, '3.4.7', self.delta_zip)
        entries = [dict(path='A', size=0, sha256='0'*64), dict(path='a', size=0, sha256='0'*64)]
        self.assertRaises(ValueError, r.validate_files, dict(schemaVersion=1, files=entries, treeSha256=r.tree_hash(entries)))

    def test_zip_traversal_rejected_before_extract(self):
        with ZipFile(self.root / 'evil.zip', 'w') as z: z.writestr('../outside', b'bad')
        self.assertRaises(ValueError, r.extract, self.root / 'evil.zip', self.root / 'stage')
        for name in ['a/../b', 'CON.txt', 'a\\b', '/a', 'x.', 'a//b', 'C:/a']:
            self.assertRaises(ValueError, r.safe_path, name)

    def test_signature_tampering_and_wrong_key(self):
        key = Ed25519PrivateKey.generate()
        seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        path = self.root / 'update.json'; path.write_bytes(b'{"version":"3.4.7"}\n')
        r.sign_manifest(path, base64.b64encode(seed).decode(), 'test')
        sig = path.with_suffix('.sig').read_bytes()
        keys = {'test': base64.b64encode(public).decode()}
        r.verify_signature(path.read_bytes(), sig, keys)
        self.assertRaises(Exception, r.verify_signature, path.read_bytes()+b' ', sig, keys)
        self.assertRaises(Exception, r.verify_signature, path.read_bytes(), sig, {})

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_windows_apply_preserves_unknown_files(self):
        (self.old / 'user-settings.json').write_bytes(b'keep')
        self.apply()
        r.verify_tree(self.old, self.target)
        self.assertFalse((self.old / 'obsolete.dll').exists())
        self.assertEqual((self.old / 'user-settings.json').read_bytes(), b'keep')

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_windows_copy_failure_restores_old_tree_and_user_data(self):
        (self.old / 'user-settings.json').write_bytes(b'keep')
        self.apply('-FailAfterCopy', '1', expected=1)
        r.verify_tree(self.old, self.source)
        self.assertFalse((self.old / 'added.dll').exists())
        self.assertEqual((self.old / 'user-settings.json').read_bytes(), b'keep')
        self.assertEqual(json.loads((self.root / 'journal.json').read_text(encoding='utf-8-sig'))['state'], 'rolled_back')

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_failed_startup_health_restores_old_tree(self):
        # A real harmless executable exits without acknowledging Flutter health.
        executable = Path(os.environ['SystemRoot']) / 'System32/whoami.exe'
        for root in (self.old, self.new): shutil.copyfile(executable, root/'resonance.exe')
        self.source = r.file_manifest(self.old, '3.4.5')
        self.target = r.file_manifest(self.new, '3.4.7')
        r.write_json(self.old/'resonance-install.json', self.source)
        r.write_json(self.new/'resonance-install.json', self.target)
        r.zip_tree(self.old, self.old_zip)
        r.windows_delta(self.old_zip, self.new, '3.4.7', self.delta_zip)
        (self.old/'user-settings.json').write_bytes(b'keep')
        self.apply('-HealthTimeout', '2', expected=1, apply_only=False)
        r.verify_tree(self.old, self.source)
        self.assertFalse((self.old/'added.dll').exists())
        self.assertEqual((self.old/'user-settings.json').read_bytes(), b'keep')
        self.assertEqual(json.loads((self.root/'journal.json').read_text(encoding='utf-8-sig'))['state'], 'rolled_back')

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_preflight_does_not_replace_files_or_create_backup(self):
        self.apply('-PreflightOnly')
        r.verify_tree(self.old, self.source)
        self.assertFalse((self.root / 'backup').exists())
        self.assertFalse((self.old / '.resonance-update-pending').exists())

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_preflight_invalid_patch_requests_full_before_app_exit(self):
        self.delta_zip.write_bytes(b'invalid signed payload')
        self.apply('-PreflightOnly', expected=10)
        r.verify_tree(self.old, self.source)
        self.assertFalse((self.root / 'backup').exists())

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_recovery_restores_interrupted_transaction(self):
        self.prepare_interrupted_transaction()
        self.apply('-RecoverOnly')
        self.assert_recovered_transaction()

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_recovery_accepts_short_windows_directory_alias(self):
        import ctypes
        from ctypes import wintypes
        # GitHub's Windows runner uses a short user profile name in TEMP.
        self.old.rename(self.root / 'old installation with spaces')
        self.old = self.root / 'old installation with spaces'
        get_short_path = ctypes.WinDLL('kernel32', use_last_error=True).GetShortPathNameW
        get_short_path.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD]
        get_short_path.restype = wintypes.DWORD
        length = get_short_path(str(self.old), None, 0)
        if not length: raise ctypes.WinError(ctypes.get_last_error())
        buffer = ctypes.create_unicode_buffer(length)
        result = get_short_path(str(self.old), buffer, length)
        if not result or result >= length: raise ctypes.WinError(ctypes.get_last_error())
        if buffer.value.lower() == str(self.old).lower():
            self.skipTest('8.3 directory aliases disabled on this volume')
        self.prepare_interrupted_transaction(buffer.value)
        self.apply('-RecoverOnly')
        self.assert_recovered_transaction()

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_recovery_accepts_equivalent_path_spelling(self):
        self.prepare_interrupted_transaction(self.old.as_posix().upper() + '/./')
        self.apply('-RecoverOnly')
        self.assert_recovered_transaction()

    @unittest.skipUnless(os.name == 'nt', 'PowerShell installer runs on Windows')
    def test_recovery_rejects_different_installation_directory(self):
        self.prepare_interrupted_transaction(str(self.new))
        self.apply('-RecoverOnly', expected=1)
        self.assertEqual((self.old/'resonance.exe').read_bytes(), b'new')
        self.assertEqual((self.old/'user-settings.json').read_bytes(), b'keep')
        self.assertEqual(json.loads((self.root/'journal.json').read_text())['state'], 'awaiting_health')
        self.assertTrue((self.old/'.resonance-update-pending').exists())

    def prepare_interrupted_transaction(self, journal_target=None):
        backup = self.root / 'backup'; backup.mkdir()
        replaced = ['resonance.exe', 'obsolete.dll', 'resonance-install.json']
        for name in replaced: shutil.copyfile(self.old/name, backup/name)
        (self.old/'resonance.exe').write_bytes(b'new')
        (self.old/'added.dll').write_bytes(b'add')
        (self.old/'obsolete.dll').unlink()
        (self.old/'user-settings.json').write_bytes(b'keep')
        r.write_json(self.old/'resonance-install.json', self.target)
        r.write_json(self.root/'journal.json', dict(state='awaiting_health', target=journal_target or str(self.old), source=self.source,
            replaced=replaced, added=['added.dll'], ownerPid=0))
        (self.old/'.resonance-update-pending').write_text(str(self.root))

    def assert_recovered_transaction(self):
        r.verify_tree(self.old, self.source)
        self.assertEqual((self.old/'user-settings.json').read_bytes(), b'keep')
        self.assertFalse((self.old/'added.dll').exists())
        self.assertFalse((self.old/'.resonance-update-pending').exists())

    def apply(self, *args, expected=0, apply_only=True):
        transaction = self.root / 'transaction.json'
        r.write_json(transaction, dict(schemaVersion=1, mode='delta', target=self.target,
            sourceTreeSha256=self.source['treeSha256'], payloadSha256=r.sha(self.delta_zip), testMode=True))
        command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            str(r.ROOT / 'assets/windows/apply_update_transaction.ps1'), '-Zip', str(self.delta_zip),
            '-Target', str(self.old), '-Transaction', str(transaction), '-ParentPid', '0',
            *(['-ApplyOnly'] if apply_only else []), *args]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr + (self.root / 'update.log').read_text())


if __name__ == '__main__': unittest.main()
