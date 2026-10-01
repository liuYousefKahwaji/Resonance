import os
from pathlib import Path
import subprocess
import tempfile
import unittest

XDELTA = os.getenv('RESONANCE_TEST_XDELTA')
DECODER = os.getenv('RESONANCE_TEST_DECODER')


@unittest.skipUnless(XDELTA and DECODER, 'Set RESONANCE_TEST_XDELTA and RESONANCE_TEST_DECODER')
class DecoderTests(unittest.TestCase):
    def test_reconstruction_wrong_source_truncation_and_output_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root/'source'; target = root/'target'; patch = root/'patch'; output = root/'output'
            original = bytes(range(256))*8192
            source.write_bytes(original)
            desired = original[:800000]+b'new data'*1000+original[900000:]
            target.write_bytes(desired)
            subprocess.run([XDELTA, '-e', '-f', '-S', 'none', '-W', '8388608', '-s', str(source), str(target), str(patch)], check=True)
            command = [DECODER, str(source), str(patch), str(output), str(len(desired))]
            self.assertEqual(subprocess.run(command).returncode, 0)
            self.assertEqual(output.read_bytes(), desired)
            for input_path in (source, patch):
                saved = input_path.read_bytes()
                self.assertNotEqual(subprocess.run([DECODER, str(source), str(patch), str(input_path), str(len(desired))]).returncode, 0)
                self.assertEqual(input_path.read_bytes(), saved)
            self.assertNotEqual(subprocess.run(command[:-1]+['16']).returncode, 0)
            self.assertFalse(output.exists())
            source.write_bytes(b'wrong source'*1000)
            self.assertNotEqual(subprocess.run(command).returncode, 0)
            self.assertFalse(output.exists())
            source.write_bytes(original)
            patch.write_bytes(patch.read_bytes()[:-5])
            self.assertNotEqual(subprocess.run(command).returncode, 0)
            self.assertFalse(output.exists())


if __name__ == '__main__': unittest.main()
