import importlib.util
import http.cookiejar
import sys
import unittest
from pathlib import Path


HELPER_PATH = (
    Path(__file__).resolve().parents[2]
    / "tool"
    / "windows_ytmusic_home"
    / "resonance_ytmusic_home.py"
)
spec = importlib.util.spec_from_file_location("windows_ytmusic_home", HELPER_PATH)
helper = importlib.util.module_from_spec(spec)
saved_yt_dlp = sys.modules.pop("yt_dlp", None)
try:
    spec.loader.exec_module(helper)
finally:
    if saved_yt_dlp is not None:
        sys.modules["yt_dlp"] = saved_yt_dlp


class WindowsYoutubeMusicHomeTests(unittest.TestCase):
    @staticmethod
    def _cookie(name, value, domain, path="/"):
        return http.cookiejar.Cookie(
            version=0,
            name=name,
            value=value,
            port=None,
            port_specified=False,
            domain=domain,
            domain_specified=True,
            domain_initial_dot=domain.startswith("."),
            path=path,
            path_specified=True,
            secure=True,
            expires=None,
            discard=False,
            comment=None,
            comment_url=None,
            rest={},
            rfc2109=False,
        )

    def test_profile_spec_is_split_without_accepting_paths(self):
        self.assertEqual(helper._browser_parts("chrome:Profile 2"), ("chrome", "Profile 2"))
        with self.assertRaises(RuntimeError):
            helper._browser_parts("chrome:../Guest")

    def test_cookie_header_is_scoped_to_the_music_endpoint(self):
        jar = http.cookiejar.CookieJar()
        jar.set_cookie(self._cookie("__Secure-3PAPISID", "youtube-secret", ".youtube.com"))
        jar.set_cookie(self._cookie("UNRELATED", "google-secret", ".google.com"))

        header = helper._cookie_header_from_jar(jar)

        self.assertIn("__Secure-3PAPISID=youtube-secret", header)
        self.assertNotIn("UNRELATED", header)

    def test_auth_headers_identify_browser_auth_and_account_slot(self):
        auth = helper._auth_headers("__Secure-3PAPISID=test-secret")

        self.assertEqual(auth["x-goog-authuser"], "0")
        self.assertEqual(auth["origin"], "https://music.youtube.com")
        self.assertTrue(auth["authorization"].startswith("SAPISIDHASH "))

    def test_playable_suggestion_gets_stable_thumbnail_fallback(self):
        track = helper._track(
            {
                "title": "Suggestion",
                "videoId": "jNQXAC9IVRw",
                "artists": [{"name": "Artist"}],
            }
        )

        self.assertEqual(
            track["thumbnail"],
            "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
        )

    def test_collection_preserves_audio_playlist_id(self):
        item = helper._item(
            {
                "title": "An album",
                "resultType": "Album",
                "audioPlaylistId": "OLAK5uy_test",
                "browseId": "MPREb_test",
            }
        )

        self.assertEqual(item["playlistId"], "OLAK5uy_test")
        self.assertEqual(item["browseId"], "MPREb_test")
        self.assertIsNone(item["track"])


if __name__ == "__main__":
    unittest.main()
