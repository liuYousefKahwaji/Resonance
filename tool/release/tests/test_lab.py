import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lab
import release as r


class WindowsLabTests(unittest.TestCase):
    def test_windows_only_feed_supports_normal_full_and_failure_modes(self):
        with tempfile.TemporaryDirectory(prefix='resonance-feed-test-') as temp:
            root = Path(temp)
            seed = root / 'test.seed'; seed.write_bytes(bytes(range(32)))
            full = root / 'resonance-v3.4.6-windows.zip'; full.write_bytes(b'full')
            files = root / 'resonance-v3.4.6-windows.files.json'; files.write_bytes(b'{}')
            patch = root / 'resonance-v3.4.5-to-v3.4.6-windows.delta.zip'; patch.write_bytes(b'patch')
            manifest = {'schemaVersion': 1, 'release': {'version': '3.4.6', 'tag': 'v3.4.6', 'notes': 'Windows test'},
                'windows': {'full': r.asset(full), 'fileManifest': r.asset(files),
                    'deltas': [{**r.asset(patch), 'sourceTreeSha256': '1' * 64}]}}
            r.write_json(root / 'resonance-v3.4.6-update.json', manifest)
            for mode in ['normal', 'full', 'wrong-source', 'corrupt-patch']:
                allowed = lab.configure(root, seed, mode, 8765)
                release = json.loads((root / 'release.json').read_bytes())
                self.assertEqual(release['tag_name'], 'v3.4.6')
                self.assertTrue(all(not asset['name'].endswith('.apk') for asset in release['assets']))
                self.assertIn(full.name, allowed)
                self.assertTrue((root / 'resonance-v3.4.6-update.sig').is_file())


if __name__ == '__main__': unittest.main()
