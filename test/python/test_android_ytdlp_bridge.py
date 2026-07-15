import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
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
        self.calls.append(options)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def extract_info(self, target, download=False):
        return type(self).responder(self, target, download)


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

    def test_stream_uses_yt_dlp_defaults_before_android_fallback(self):
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
        self.assertEqual(clients, ["android_vr", "web_embedded"])

    def test_stream_accepts_hls_and_does_not_filter_protocols(self):
        FakeYoutubeDL.responder = lambda *_: {"url": "https://cdn.example/audio.m3u8"}
        self.assertTrue(bridge.get_stream_url("https://youtu.be/test").endswith(".m3u8"))
        self.assertEqual(len(FakeYoutubeDL.calls), 1)
        self.assertNotIn("protocol^=http", FakeYoutubeDL.calls[0]["format"])

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
            bridge.download("https://youtu.be/jNQXAC9IVRw", directory, sink)

        self.assertTrue(any(event.startswith("track:") for event in sink.events))
        self.assertEqual(sink.events[-1], "done")
        self.assertEqual(
            FakeYoutubeDL.calls[0]["format"],
            "bestaudio[has_drm!=true]/best[has_drm!=true]",
        )
        self.assertNotIn("postprocessors", FakeYoutubeDL.calls[0])


if __name__ == "__main__":
    unittest.main()
