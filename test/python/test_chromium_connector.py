import base64
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import urllib.request

REPO = Path(__file__).resolve().parents[2]
MODULE = REPO / "tool/windows_ytmusic_home/chromium_connector.py"
spec = importlib.util.spec_from_file_location("chromium_connector", MODULE)
connector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(connector)


class ChromiumConnectorTests(unittest.TestCase):
    def test_extension_identity_and_youtube_only_permissions_match_native_host(self):
        manifest = json.loads((REPO / "assets/browser_connector/manifest.json").read_text())
        digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
        expected = "".join(chr(ord("a") + int(char, 16)) for char in digest)
        self.assertEqual(connector.EXTENSION_ID, expected)
        self.assertEqual(manifest["host_permissions"], ["https://*.youtube.com/*"])
        self.assertNotIn("externally_connectable", manifest)
        self.assertNotIn("content_scripts", manifest)
        self.assertEqual(manifest["incognito"], "not_allowed")

    def test_native_message_framing_is_binary_and_rejects_other_origins_and_bad_lengths(self):
        payload = json.dumps({"command": "pending"}).encode()
        output = io.BytesIO()
        with patch.object(connector, "native_request", return_value={"ok": True}) as handler:
            self.assertEqual(connector.serve(connector.ORIGIN, io.BytesIO(struct.pack("<I", len(payload)) + payload), output), 0)
            handler.assert_called_once_with({"command": "pending"})
        result = output.getvalue()
        self.assertEqual(struct.unpack("<I", result[:4])[0], len(result[4:]))
        self.assertEqual(json.loads(result[4:]), {"ok": True})
        with patch.object(connector, "native_request") as handler:
            for origin, data in [("chrome-extension://other/", b""), (connector.ORIGIN, struct.pack("<I", connector.MAX_BYTES + 1)), (connector.ORIGIN, struct.pack("<I", 30) + b"{}")]:
                self.assertEqual(connector.serve(origin, io.BytesIO(data), io.BytesIO()), 1)
            handler.assert_not_called()

    def test_cookie_validation_blocks_unrelated_sites_and_netscape_line_injection(self):
        good = {"domain": ".youtube.com", "name": "SID", "value": "fake", "path": "/"}
        for bad in [{**good, "domain": ".google.com"}, {**good, "domain": "notyoutube.com"}, {**good, "value": "fake\nnew-cookie"}, {**good, "expirationDate": float("nan")}]:
            with self.assertRaises(RuntimeError):
                connector.normalized_cookies([bad])
        normalized = connector.normalized_cookies([good, {**good, "expirationDate": time.time() - 60}])
        self.assertEqual(len(normalized), 1)
        for bad in ["chrome+connector:../../file", "firefox+connector:" + "a" * 32, "chrome:Default"]:
            with self.assertRaises(RuntimeError):
                connector.source_parts(bad)

    @unittest.skipUnless(os.name == "nt", "Windows DPAPI and file locking")
    def test_real_dpapi_export_activation_and_revocation_preserve_account_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(connector, "root", return_value=Path(temporary)):
            token = "a" * 32
            source = f"chrome+connector:{token}"
            permit = Path(temporary) / f"{token}.permit.json"
            info = {"source": source, "browser": "chrome", "created": time.time(), "state": "pending"}
            permit.write_text(json.dumps(info))
            self.assertEqual(connector.native_request({"command": "pending"})["source"], source)
            cookies = [{"domain": ".youtube.com", "name": name, "value": "fake-secret-" + name, "path": "/", "secure": True} for name in ["LOGIN_INFO", "__Secure-3PAPISID"]]
            self.assertTrue(connector.native_request({"command": "export", "source": source, "cookies": cookies})["ok"])
            snapshot = Path(temporary) / f"{token}.session"
            self.assertNotIn(b"fake-secret", snapshot.read_bytes())
            self.assertEqual(connector.read_snapshot(source)[0]["value"], "fake-secret-LOGIN_INFO")
            jar = connector.load_cookie_jar(source)
            request = urllib.request.Request("https://music.youtube.com/youtubei/v1/browse")
            jar.add_cookie_header(request)
            self.assertIn("fake-secret-LOGIN_INFO", request.get_header("Cookie"))
            unrelated = urllib.request.Request("https://google.com/")
            jar.add_cookie_header(unrelated)
            self.assertIsNone(unrelated.get_header("Cookie"))
            with patch.object(sys, "argv", ["helper", "--connector-tool", "activate", "--source", source]), redirect_stdout(io.StringIO()):
                connector.main()
            self.assertEqual(json.loads(permit.read_text())["state"], "active")
            with patch.object(sys, "argv", ["helper", "--connector-tool", "revoke", "--source", source]), redirect_stdout(io.StringIO()):
                connector.main()
            self.assertFalse(permit.exists())
            self.assertFalse(snapshot.exists())
            with self.assertRaises(RuntimeError):
                connector.native_request({"command": "export", "source": source, "cookies": cookies})

    @unittest.skipUnless(os.name == "nt", "Windows DPAPI and file locking")
    def test_logout_invalidates_the_previous_session_and_pending_tickets_expire(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(connector, "root", return_value=Path(temporary)):
            token = "b" * 32
            source = f"edge+connector:{token}"
            path = Path(temporary) / f"{token}.permit.json"
            path.write_text(json.dumps({"source": source, "browser": "edge", "state": "active", "created": time.time()}))
            snapshot = Path(temporary) / f"{token}.session"
            snapshot.write_bytes(b"previous encrypted session")
            with self.assertRaises(RuntimeError):
                connector.native_request({"command": "export", "source": source, "cookies": []})
            self.assertFalse(snapshot.exists())
            path.write_text(json.dumps({"source": source, "browser": "edge", "state": "pending", "created": time.time() - 601}))
            with self.assertRaises(RuntimeError):
                connector.permit(source)


if __name__ == "__main__":
    unittest.main()
