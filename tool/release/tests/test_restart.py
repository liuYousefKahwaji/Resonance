"""Exercise the real Windows restart helper without starting the music player."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(os.name == 'nt', 'Windows process handoff')
class RestartTests(unittest.TestCase):
    def test_acknowledges_before_exit_and_waits_for_parent(self):
        with tempfile.TemporaryDirectory(prefix='resonance restart test ') as temp:
            root = Path(temp)
            script = root / 'restart.ps1'
            shutil.copyfile(Path(__file__).resolve().parents[3] / 'assets/windows/restart_app.ps1', script)
            executable = root / 'test replacement.exe'
            shutil.copyfile(Path(os.environ['SystemRoot']) / 'System32/whoami.exe', executable)
            ready = root / 'ready'
            flags = subprocess.CREATE_NO_WINDOW
            parent = subprocess.Popen(['powershell.exe', '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'], creationflags=flags)
            helper = subprocess.Popen(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(script), '-Executable', str(executable), '-ParentPid', str(parent.pid), '-ReadyFile', str(ready)],
                creationflags=flags, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 15
                while not ready.exists() and helper.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(ready.exists())
                self.assertEqual(int(ready.read_text()), helper.pid)
                self.assertIsNone(parent.poll())
                self.assertNotIn('Relaunched', (root / 'restart.log').read_text())
                parent.terminate(); parent.wait(timeout=5)
                _, errors = helper.communicate(timeout=20)
                self.assertEqual(helper.returncode, 0, errors.decode(errors='replace'))
                self.assertIn('Relaunched process', (root / 'restart.log').read_text())
            finally:
                for process in [parent, helper]:
                    if process.poll() is None: process.kill(); process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
