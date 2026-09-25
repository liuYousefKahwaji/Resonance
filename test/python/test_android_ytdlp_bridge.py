import importlib.util
import base64
import json
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from pathlib import Path


BRIDGE_PATH = (
    Path(__file__).resolve().parents[2]
    / "android"
    / "app"
    / "src"
    / "main"
    / "python"
    / "ytdlp_bridge.py"
)


class FakeYoutubeDL:
    calls = []
    responder = None

    def __init__(self, options):
        self.options = options
        self.cookiejar = FakeCookieJar()
        self.calls.append(options)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def extract_info(self, target, download=False):
        return type(self).responder(self, target, download)


class FakeCookieJar:
    header = None

    def get_cookie_header(self, _url):
        return type(self).header


fake_yt_dlp = types.ModuleType("yt_dlp")
fake_yt_dlp.YoutubeDL = FakeYoutubeDL
sys.modules["yt_dlp"] = fake_yt_dlp
spec = importlib.util.spec_from_file_location("android_ytdlp_bridge", BRIDGE_PATH)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class EventSink:
    def __init__(self):
        self.events = []

    def success(self, message):
        self.events.append(message)


class AndroidYtdlpBridgeTests(unittest.TestCase):
    def setUp(self):
        FakeYoutubeDL.calls = []
        FakeCookieJar.header = None
        bridge._QUICKJS_PATH = None
        self._guest_music_patch = patch.dict(sys.modules, {"ytmusicapi": types.ModuleType("ytmusicapi")})
        self._guest_music_patch.start()
        self.addCleanup(self._guest_music_patch.stop)

    def test_search_uses_one_guest_music_request_when_results_are_available(self):
        fake_ytmusic = types.ModuleType("ytmusicapi")

        class FakeMusic:
            def __init__(self, language):
                self.language = language

            def search(self, query, filter, limit):
                self.assertion = (query, filter, limit)
                return [{"title": "Quick result", "videoId": "jNQXAC9IVRw", "artists": [{"name": "Artist"}]}]

        fake_ytmusic.YTMusic = FakeMusic
        with patch.dict(sys.modules, {"ytmusicapi": fake_ytmusic}):
            results = json.loads(bridge.search("quick result", 2))
        self.assertEqual(results[0]["title"], "Quick result")
        self.assertEqual(FakeYoutubeDL.calls, [])

    def test_related_radio_uses_guest_client_and_excludes_seed_and_duplicates(self):
        fake_ytmusic = types.ModuleType("ytmusicapi")

        class FakeMusic:
            def __init__(self, language):
                self.language = language

            def get_watch_playlist(self, **_):
                return {"tracks": [
                    {"title": "Seed", "videoId": "dQw4w9WgXcQ"},
                    {"title": "Next", "videoId": "jNQXAC9IVRw"},
                    {"title": "Duplicate", "videoId": "jNQXAC9IVRw"},
                    {"title": "Then", "videoId": "yPYZpwSpKmA"},
                ]}

        fake_ytmusic.YTMusic = FakeMusic
        with patch.dict(sys.modules, {"ytmusicapi": fake_ytmusic}):
            tracks = json.loads(bridge.get_music_related("dQw4w9WgXcQ", 1))["tracks"]

        self.assertEqual([track["title"] for track in tracks], ["Next"])

    def test_bundled_quickjs_is_enabled_for_every_yt_dlp_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "libresonance_qjs.so"
            runtime.write_bytes(b"fake executable")
            self.assertTrue(bridge.configure_runtime(directory))
            FakeYoutubeDL.responder = lambda *_: {"url": "https://cdn.example/audio.m4a"}

            bridge.get_stream_url("https://youtu.be/test")

            self.assertEqual(
                FakeYoutubeDL.calls[0]["js_runtimes"],
                {"quickjs": {"path": str(runtime)}},
            )

    def test_home_item_preserves_non_playable_collections(self):
        item = bridge._normalize_music_home_item(
            {
                "title": "A new release",
                "resultType": "Album",
                "artists": [{"name": "Artist"}],
                "thumbnails": [{"url": "https://img.example/album"}],
                "audioPlaylistId": "OLAK5uy_test",
                "browseId": "MPREb_test",
            }
        )

        self.assertEqual(item["kind"], "Album")
        self.assertEqual(item["subtitle"], "Artist")
        self.assertIsNone(item["track"])
        self.assertEqual(item["playlistId"], "OLAK5uy_test")
        self.assertEqual(item["browseId"], "MPREb_test")

    def test_music_tracks_always_have_artwork_fallback(self):
        item = bridge._normalize_music_item(
            {"title": "Suggestion", "videoId": "jNQXAC9IVRw", "artists": [{"name": "Artist"}]}
        )

        self.assertEqual(item["thumbnail"], "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg")

    def test_music_history_rejects_invalid_id_before_cookie_or_network_access(self):
        with self.assertRaisesRegex(RuntimeError, "video ID is invalid"):
            bridge.add_music_history("invalid")

    def test_music_history_uses_one_authenticated_client_and_requires_204(self):
        class Response:
            status_code = 204

        class FakeMusic:
            instances = []

            def __init__(self, auth, language):
                self.auth = auth
                self.language = language
                self.calls = []
                self.instances.append(self)

            def get_song(self, video_id):
                self.calls.append(("get_song", video_id))
                return {"videoId": video_id}

            def add_history_item(self, song):
                self.calls.append(("add_history_item", song))
                return Response()

        fake_ytmusic = types.ModuleType("ytmusicapi")
        fake_ytmusic.YTMusic = FakeMusic
        fake_helpers = types.ModuleType("ytmusicapi.helpers")
        fake_helpers.get_authorization = lambda _value: "SAPISIDHASH test"
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = Path(directory) / "cookies.txt"
            cookie_file.write_text(
                "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t2147483647\t__Secure-3PAPISID\ttest-secret\n",
                encoding="utf-8",
            )
            with patch.dict(sys.modules, {"ytmusicapi": fake_ytmusic, "ytmusicapi.helpers": fake_helpers}):
                result = json.loads(bridge.add_music_history("jNQXAC9IVRw", str(cookie_file)))

        self.assertEqual(result, {"ok": True, "videoId": "jNQXAC9IVRw", "statusCode": 204})
        self.assertEqual(len(FakeMusic.instances), 1)
        self.assertEqual(FakeMusic.instances[0].calls, [
            ("get_song", "jNQXAC9IVRw"),
            ("add_history_item", {"videoId": "jNQXAC9IVRw"}),
        ])

    def test_stream_uses_yt_dlp_defaults_before_android_vr_fallback(self):
        def respond(ydl, _target, _download):
            if "extractor_args" not in ydl.options:
                raise RuntimeError("No video formats found; use --list-formats")
            return {"url": "https://cdn.example/audio.webm"}

        FakeYoutubeDL.responder = respond
        self.assertEqual(
            bridge.get_stream_url("https://youtu.be/jNQXAC9IVRw"),
            "https://cdn.example/audio.webm",
        )
        self.assertNotIn("extractor_args", FakeYoutubeDL.calls[0])
        clients = FakeYoutubeDL.calls[1]["extractor_args"]["youtube"]["player_client"]
        self.assertEqual(clients, ["android_vr"])

    def test_android_vr_fallback_omits_cookies_instead_of_being_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text(
                "# Netscape HTTP Cookie File\n", encoding="utf-8"
            )

            def respond(ydl, _target, _download):
                clients = (
                    ydl.options.get("extractor_args", {})
                    .get("youtube", {})
                    .get("player_client", [])
                )
                if clients == ["android_vr"]:
                    return {"url": "https://cdn.example/combined.mp4"}
                raise RuntimeError("Signature solving failed; only images are available")

            FakeYoutubeDL.responder = respond
            result = bridge.get_stream_url(
                "https://youtu.be/UWt4fIDMJ00", cookie_file
            )

            self.assertEqual(result, "https://cdn.example/combined.mp4")
            self.assertNotIn("cookiefile", FakeYoutubeDL.calls[0])
            self.assertNotIn("cookiefile", FakeYoutubeDL.calls[1])
            self.assertEqual(
                FakeYoutubeDL.calls[1]["extractor_args"]["youtube"]["player_client"],
                ["android_vr"],
            )

    def test_web_embedded_remains_last_cookie_capable_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text(
                "# Netscape HTTP Cookie File\n", encoding="utf-8"
            )

            def respond(ydl, _target, _download):
                clients = (
                    ydl.options.get("extractor_args", {})
                    .get("youtube", {})
                    .get("player_client", [])
                )
                if clients == ["web_embedded"]:
                    return {"url": "https://cdn.example/embedded.m4a"}
                raise RuntimeError("No playable formats")

            FakeYoutubeDL.responder = respond
            result = bridge.get_stream_url("https://youtu.be/test", cookie_file)

            self.assertEqual(result, "https://cdn.example/embedded.m4a")
            self.assertEqual(len(FakeYoutubeDL.calls), 4)
            self.assertEqual(FakeYoutubeDL.calls[2]["cookiefile"], cookie_file)
            self.assertEqual(FakeYoutubeDL.calls[3]["cookiefile"], cookie_file)
            self.assertEqual(
                FakeYoutubeDL.calls[3]["extractor_args"]["youtube"]["player_client"],
                ["web_embedded"],
            )

    def test_stream_accepts_hls_and_does_not_filter_protocols(self):
        FakeYoutubeDL.responder = lambda *_: {"url": "https://cdn.example/audio.m3u8"}
        self.assertTrue(bridge.get_stream_url("https://youtu.be/test").endswith(".m3u8"))
        self.assertEqual(len(FakeYoutubeDL.calls), 1)
        self.assertNotIn("protocol^=http", FakeYoutubeDL.calls[0]["format"])

    def test_stream_data_returns_selected_headers_and_url_scoped_cookie(self):
        FakeCookieJar.header = "scoped=fake"
        FakeYoutubeDL.responder = lambda *_: {
            "requested_downloads": [{
                "url": "https://cdn.example/audio.m4a",
                "http_headers": {"User-Agent": "fake-agent", "Referer": "https://www.youtube.com/"},
            }],
            "http_headers": {"User-Agent": "wrong"},
        }
        result = json.loads(bridge.get_stream_data("https://youtu.be/test"))
        self.assertEqual(result["url"], "https://cdn.example/audio.m4a")
        self.assertEqual(result["headers"]["User-Agent"], "fake-agent")
        self.assertEqual(result["headers"]["Cookie"], "scoped=fake")

    def test_stream_data_includes_title_and_artist_without_second_extraction(self):
        FakeYoutubeDL.responder = lambda *_: {
            "url": "https://cdn.example/audio.m4a",
            "title": "Quick title",
            "uploader": "Quick artist",
            "thumbnail": "https://img.example/cover.jpg",
        }
        result = json.loads(bridge.get_stream_data("https://youtu.be/jNQXAC9IVRw"))
        self.assertEqual(result["title"], "Quick title")
        self.assertEqual(result["artist"], "Quick artist")
        self.assertEqual(result["thumbnail"], "https://img.example/cover.jpg")
        self.assertEqual(len(FakeYoutubeDL.calls), 1)

    def test_superseded_stream_stops_before_trying_other_player_clients(self):
        class CancelFlag:
            def __init__(self):
                self.value = False

            def get(self):
                return self.value

        flag = CancelFlag()

        def respond(_ydl, _target, _download):
            flag.value = True
            raise RuntimeError("Old request was interrupted")

        FakeYoutubeDL.responder = respond
        with self.assertRaises(bridge.StreamRequestCancelled):
            bridge.get_stream_data("https://youtu.be/jNQXAC9IVRw", cancelled=flag)
        self.assertEqual(len(FakeYoutubeDL.calls), 1)

    def test_authenticated_retry_is_available_after_guest_login_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text("# Netscape HTTP Cookie File\n", encoding="utf-8")

            def respond(ydl, _target, _download):
                if ydl.options.get("cookiefile") == cookie_file:
                    return {"url": "https://cdn.example/private.m4a"}
                raise RuntimeError("Sign in to confirm you're not a bot")

            FakeYoutubeDL.responder = respond
            result = json.loads(bridge.get_stream_data("https://youtu.be/jNQXAC9IVRw", cookie_file))
            self.assertEqual(result["url"], "https://cdn.example/private.m4a")
            self.assertNotIn("cookiefile", FakeYoutubeDL.calls[0])
            self.assertEqual(FakeYoutubeDL.calls[-1]["cookiefile"], cookie_file)

    def test_search_uses_default_clients_and_returns_json(self):
        FakeYoutubeDL.responder = lambda *_: {
            "entries": [
                {
                    "title": "Me at the zoo",
                    "uploader": "jawed",
                    "url": "https://www.youtube.com/watch?v=jNQXAC9IVRw",
                    "duration": 19,
                }
            ]
        }
        result = json.loads(bridge.search("me at the zoo"))
        self.assertEqual(result[0]["title"], "Me at the zoo")
        self.assertNotIn("extractor_args", FakeYoutubeDL.calls[0])

    def test_flat_search_failure_does_not_repeat_video_player_fallbacks(self):
        FakeYoutubeDL.responder = lambda *_: (_ for _ in ()).throw(RuntimeError("Network unavailable"))

        with self.assertRaisesRegex(RuntimeError, "Network unavailable"):
            bridge.search("any song")

        self.assertEqual(len(FakeYoutubeDL.calls), 1)

    def test_stream_resolution_uses_one_format_chain(self):
        FakeYoutubeDL.responder = lambda *_: {"url": "https://cdn.example/audio.m4a"}

        bridge.get_stream_data("https://youtu.be/jNQXAC9IVRw")

        self.assertEqual(len(FakeYoutubeDL.calls), 1)
        self.assertIn("/bestaudio/best", FakeYoutubeDL.calls[0]["format"])

    def test_playable_music_home_skips_optional_network_enrichment(self):
        class FakeMusic:
            def __init__(self):
                self.calls = []

            def get_home(self, limit):
                self.calls.append(("home", limit))
                return [{"title": "Songs", "contents": [
                    {"title": f"Song {index}", "videoId": f"aaaaaaaaaa{index}"}
                    for index in range(4)
                ]}]

            def get_history(self):
                self.calls.append(("history",))
                return []

            def get_watch_playlist(self, **_):
                self.calls.append(("radio",))
                return {}

        music = FakeMusic()
        with patch.object(bridge, "_build_authenticated_ytmusic", return_value=music):
            result = json.loads(bridge.get_music_home())

        self.assertEqual(music.calls, [("home", 24)])
        self.assertTrue(result["shelves"])

    def test_collection_only_home_tries_one_more_collection_if_first_is_empty(self):
        class FakeMusic:
            def __init__(self):
                self.playlists = []

            def get_home(self, limit):
                return [{"title": "Albums", "contents": [
                    {"title": "Empty", "playlistId": "first"},
                    {"title": "Playable", "playlistId": "second"},
                ]}]

            def get_history(self):
                return []

            def get_playlist(self, playlist_id, limit):
                self.playlists.append(playlist_id)
                return {"tracks": [] if playlist_id == "first" else [
                    {"title": "Song", "videoId": "jNQXAC9IVRw"},
                ]}

            def get_watch_playlist(self, **_):
                return {}

        music = FakeMusic()
        with patch.object(bridge, "_build_authenticated_ytmusic", return_value=music):
            result = json.loads(bridge.get_music_home())

        self.assertEqual(music.playlists, ["first", "second"])
        self.assertTrue(any(shelf["title"] == "Quick picks" for shelf in result["shelves"]))

    def test_cookie_file_is_optional_and_propagates_to_all_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text("# Netscape HTTP Cookie File\n", encoding="utf-8")

            FakeYoutubeDL.responder = lambda ydl, target, download: (
                {"entries": [{"id": "jNQXAC9IVRw", "url": "https://cdn.example/a", "thumbnail": "https://img.example/a"}]}
                if target.startswith("ytsearch")
                else {"id": "jNQXAC9IVRw", "title": "Track", "url": "https://cdn.example/a", "entries": [{"id": "jNQXAC9IVRw"}]}
            )

            bridge.search("test", 1, cookie_file)
            bridge.get_metadata("https://youtu.be/test", cookie_file)
            bridge.get_playlist_metadata("https://youtube.com/playlist?list=test", cookie_file)
            bridge.get_first_thumbnail("test", cookie_file)
            bridge.get_stream_data("https://youtu.be/test", cookie_file)
            bridge.test_access("https://youtu.be/test", cookie_file)

            self.assertGreaterEqual(len(FakeYoutubeDL.calls), 6)
            self.assertEqual(
                sum(call.get("cookiefile") == cookie_file for call in FakeYoutubeDL.calls),
                len(FakeYoutubeDL.calls) - 1,
            )

            FakeYoutubeDL.calls = []
            bridge.search("anonymous", 1)
            self.assertNotIn("cookiefile", FakeYoutubeDL.calls[0])

    def test_access_probe_uses_a_live_search_result_video_id(self):
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text(
                "# Netscape HTTP Cookie File\n", encoding="utf-8"
            )
            FakeYoutubeDL.responder = lambda *_: {
                "id": "YouTube music",
                "entries": [{"id": "jNQXAC9IVRw"}],
            }

            result = json.loads(
                bridge.test_access("ytsearch1:YouTube music", cookie_file)
            )

            self.assertEqual(result, {"ok": True, "id": "jNQXAC9IVRw"})
            self.assertEqual(FakeYoutubeDL.calls[0]["cookiefile"], cookie_file)

    def test_stream_preserves_the_underlying_verification_error(self):
        FakeYoutubeDL.responder = lambda *_: (_ for _ in ()).throw(
            RuntimeError("Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies")
        )
        with self.assertRaisesRegex(RuntimeError, "Sign in to confirm"):
            bridge.get_stream_data("https://youtu.be/test")
        self.assertEqual(len(FakeYoutubeDL.calls), 1)

    def test_network_timeout_does_not_retry_with_other_player_clients(self):
        FakeYoutubeDL.responder = lambda *_: (_ for _ in ()).throw(RuntimeError("The connection timed out"))

        with self.assertRaisesRegex(RuntimeError, "timed out"):
            bridge.get_stream_data("https://youtu.be/test")

        self.assertEqual(len(FakeYoutubeDL.calls), 1)

    def test_rotated_account_cookie_warning_is_preserved_as_an_error(self):
        def respond(ydl, _target, _download):
            ydl.options["logger"].warning(
                "The provided YouTube account cookies are no longer valid"
            )
            return {"id": "jNQXAC9IVRw"}

        FakeYoutubeDL.responder = respond
        with tempfile.TemporaryDirectory() as directory:
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text(
                "# Netscape HTTP Cookie File\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(RuntimeError, "no longer valid"):
                bridge.test_access("https://youtu.be/test", cookie_file)

    def test_playlist_metadata_preserves_order_and_uses_flat_extraction(self):
        FakeYoutubeDL.responder = lambda *_: {
            "title": "Road Trip",
            "entries": [
                {
                    "id": "aaaaaaaaaaa",
                    "title": "First",
                    "uploader": "Artist A",
                    "duration": 61,
                },
                {
                    "id": "aaaaaaaaaaa",
                    "title": "First",
                    "uploader": "Artist A",
                    "duration": 61,
                },
                {
                    "id": "bbbbbbbbbbb",
                    "title": "Last",
                    "channel": "Artist B",
                    "duration": 125,
                },
            ],
        }

        result = json.loads(
            bridge.get_playlist_metadata(
                "https://music.youtube.com/playlist?list=PLtest"
            )
        )

        self.assertEqual(result["title"], "Road Trip")
        self.assertEqual(
            [entry["id"] for entry in result["entries"]],
            ["aaaaaaaaaaa", "aaaaaaaaaaa", "bbbbbbbbbbb"],
        )
        self.assertEqual(FakeYoutubeDL.calls[0]["extract_flat"], "in_playlist")
        self.assertFalse(FakeYoutubeDL.calls[0]["noplaylist"])
        self.assertEqual(FakeYoutubeDL.calls[0]["playlistend"], 1000)

    def test_download_emits_track_and_done_without_desktop_ffmpeg(self):
        sink = EventSink()
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "track.webm")
            Path(path).write_bytes(b"audio")
            cookie_file = os.path.join(directory, "cookies.txt")
            Path(cookie_file).write_text("# Netscape HTTP Cookie File\n", encoding="utf-8")

            def respond(ydl, _target, download):
                self.assertTrue(download)
                info = {
                    "title": "Track",
                    "uploader": "Artist",
                    "id": "jNQXAC9IVRw",
                }
                ydl.options["progress_hooks"][0](
                    {"status": "finished", "filename": path, "info_dict": info}
                )
                return info

            FakeYoutubeDL.responder = respond
            bridge.download("https://youtu.be/jNQXAC9IVRw", directory, sink, cookie_file)

        self.assertTrue(any(event.startswith("track-json:") for event in sink.events))
        self.assertEqual(sink.events[-1], "done")
        self.assertEqual(
            FakeYoutubeDL.calls[0]["format"],
            "bestaudio[has_drm!=true]/best[has_drm!=true]",
        )
        self.assertNotIn("postprocessors", FakeYoutubeDL.calls[0])
        self.assertEqual(FakeYoutubeDL.calls[0]["cookiefile"], cookie_file)

    def test_music_history_is_normalized_and_bounded(self):
        class FakeMusic:
            def get_history(self):
                return [
                    {"videoId": "abcdefghijk", "title": "First", "artists": [{"name": "Artist"}]},
                    {"videoId": "lmnopqrstuv", "title": "Second", "artists": [{"name": "Other"}]},
                ]

        original = bridge._build_authenticated_ytmusic
        bridge._build_authenticated_ytmusic = lambda _cookie: FakeMusic()
        try:
            payload = json.loads(bridge.get_music_history(1, "private-cookies.txt"))
        finally:
            bridge._build_authenticated_ytmusic = original
        self.assertEqual(len(payload["tracks"]), 1)
        self.assertEqual(payload["tracks"][0]["title"], "First")

    def test_download_event_preserves_unicode_metadata_and_filename_as_utf8(self):
        cases = [
            ("øneheart - apathy (slowed)", "øneheart"),
            ("São Paulo (Official Audio)", "Anitta"),
            ("東京の夜", "宇多田ヒカル"),
            ("midnight drive 🎧", "artist ✨"),
        ]

        for index, (title, artist) in enumerate(cases):
            with self.subTest(title=title), tempfile.TemporaryDirectory() as directory:
                filename = f"{title}.webm"
                path = os.path.join(directory, filename)
                Path(path).write_bytes(b"audio")
                sink = EventSink()

                def respond(ydl, _target, download):
                    self.assertTrue(download)
                    info = {
                        "title": title,
                        "uploader": artist,
                        "id": f"unicode{index:04d}"[-11:],
                    }
                    ydl.options["progress_hooks"][0](
                        {"status": "finished", "filename": path, "info_dict": info}
                    )
                    return info

                FakeYoutubeDL.responder = respond
                bridge.download("https://youtu.be/unicodeTest", directory, sink)

                track_message = next(
                    event for event in sink.events if event.startswith("track-json:")
                )
                payload = json.loads(
                    base64.b64decode(track_message.removeprefix("track-json:")).decode(
                        "utf-8"
                    )
                )
                self.assertEqual(payload["path"], path)
                self.assertEqual(payload["title"], title)
                self.assertEqual(payload["artist"], artist)
                self.assertEqual(Path(payload["path"]).name, filename)
                self.assertFalse(FakeYoutubeDL.calls[-1]["restrictfilenames"])
                self.assertFalse(FakeYoutubeDL.calls[-1]["windowsfilenames"])


if __name__ == "__main__":
    unittest.main()
