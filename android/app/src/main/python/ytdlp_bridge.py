# android/app/src/main/python/ytdlp_bridge.py
#
# Chaquopy Python bridge for yt-dlp on Android.
#
# get_stream_url() fix:
#   Previously returned a raw CDN chunk URL. Raw CDN URLs for YouTube
#   typically require cookies/headers and don't support HTTP range requests
#   the way just_audio expects for seeking. The fix is to return an HLS
#   (.m3u8) manifest URL instead, which just_audio (via ExoPlayer on Android)
#   handles natively with full seek support.
#   Format selector: "hls/bestaudio[ext=m4a]/bestaudio/best"
#   - hls: prefers HLS manifest (ExoPlayer handles seeking transparently)
#   - bestaudio[ext=m4a]: direct m4a CDN fallback (single stream, seekable)
#   - bestaudio/best: last resort

import base64
import json
import os
import yt_dlp


# ── Shared yt-dlp options ──────────────────────────────────────────────────────

_BASE_OPTS = {
    "quiet": True,
    "extractor_retries": 3,
    "socket_timeout": 20,
}

_MAX_DIAGNOSTIC_CHARS = 4096


class _DiagnosticLogger:
    """Capture bounded yt-dlp warnings/errors instead of writing them to logcat."""

    def __init__(self):
        self.messages = []

    def debug(self, _message):
        pass

    def info(self, _message):
        pass

    def warning(self, message):
        self._record(message)

    def error(self, message):
        self._record(message)

    def _record(self, message):
        text = " ".join(str(message).split())
        if text and text not in self.messages:
            self.messages.append(text[:1024])
            while len(" | ".join(self.messages)) > _MAX_DIAGNOSTIC_CHARS:
                self.messages.pop(0)

    @property
    def summary(self):
        return " | ".join(self.messages)

    @property
    def account_cookies_invalid(self):
        return "account cookies are no longer valid" in self.summary.lower()

# Let yt-dlp choose its maintained default clients first. Hard-coding
# web_embedded,tv_simply caused ordinary public videos to return no formats as
# YouTube changed its PO-token policy. android_vr remains the first fallback
# because it does not need a JavaScript runtime, but yt-dlp intentionally skips
# it whenever a cookie file is supplied. Run that attempt without cookies, then
# try the cookie-capable web_embedded client last. This preserves authenticated
# extraction as the primary path without making imported cookies disable the
# Android-safe fallback.
_ANDROID_VR_EXTRACTOR_ARGS = {
    "youtube": {"player_client": ["android_vr"]},
}
_WEB_EMBEDDED_EXTRACTOR_ARGS = {
    "youtube": {"player_client": ["web_embedded"]},
}


def _make_ydl(extra=None, cookie_file=None, logger=None):
    opts = dict(_BASE_OPTS)
    if extra:
        opts.update(extra)
    if cookie_file:
        if not os.path.isfile(cookie_file):
            raise RuntimeError("The configured YouTube cookie file is unavailable")
        opts["cookiefile"] = cookie_file
    if logger:
        opts["logger"] = logger
    return yt_dlp.YoutubeDL(opts)


def _extract_info(target, extra=None, download=False, cookie_file=None, transform=None):
    """Extract with defaults, cookie-free android_vr, then web_embedded."""
    android_vr = dict(extra or {})
    android_vr["extractor_args"] = _ANDROID_VR_EXTRACTOR_ARGS
    web_embedded = dict(extra or {})
    web_embedded["extractor_args"] = _WEB_EMBEDDED_EXTRACTOR_ARGS
    attempts = [
        (dict(extra or {}), cookie_file),
        (android_vr, None),
        (web_embedded, cookie_file),
    ]
    last_error = None
    for opts, attempt_cookie_file in attempts:
        logger = _DiagnosticLogger()
        try:
            with _make_ydl(opts, cookie_file=attempt_cookie_file, logger=logger) as ydl:
                info = ydl.extract_info(target, download=download)
                if logger.account_cookies_invalid:
                    raise RuntimeError(logger.summary)
                return (transform(info, ydl) if transform else info), ydl
        except Exception as error:
            detail = logger.summary
            message = str(error)
            last_error = (
                RuntimeError(f"{message} | {detail}")
                if detail and detail not in message
                else error
            )
    raise last_error or RuntimeError(f"Could not extract: {target}")


# ── search ─────────────────────────────────────────────────────────────────────

def search(query: str, limit: int = 10, cookie_file=None) -> str:
    """Return a JSON array capped to the requested search result count."""
    result_limit = max(1, min(int(limit), 10))
    opts = {
        "extract_flat": True,
        "skip_download": True,
    }
    info, _ = _extract_info(f"ytsearch{result_limit}:{query}", opts, cookie_file=cookie_file)

    results = []
    for entry in (info.get("entries") or []):
        title = entry.get("title") or "Unknown"
        uploader = (
            entry.get("uploader")
            or entry.get("channel")
            or entry.get("uploader_id")
            or "Unknown"
        )
        url = entry.get("webpage_url") or entry.get("url") or ""
        duration = entry.get("duration")
        thumbnail = entry.get("thumbnail") or ""
        thumbnails = entry.get("thumbnails") or []
        if thumbnails:
            thumbnail = (thumbnails[-1] or {}).get("url") or thumbnail
        results.append({
            "title": title,
            "uploader": uploader,
            "url": url,
            "duration_seconds": int(duration) if duration else None,
            "thumbnail": thumbnail,
            "view_count": entry.get("view_count"),
            "like_count": entry.get("like_count"),
            "live_status": entry.get("live_status"),
            "availability": entry.get("availability"),
            "is_short": "/shorts/" in str(entry.get("original_url") or entry.get("webpage_url") or ""),
        })

    return json.dumps(results, ensure_ascii=False)


# ── get_metadata ───────────────────────────────────────────────────────────────

def get_metadata(url: str, cookie_file=None) -> str:
    """Return JSON object with title and artist for a single video."""
    opts = {
        "skip_download": True,
        "extract_flat": False,
    }
    info, _ = _extract_info(url, opts, cookie_file=cookie_file)

    title = info.get("title") or "Streaming Track"
    artist = (
        info.get("uploader")
        or info.get("channel")
        or info.get("uploader_id")
        or "YouTube"
    )
    thumbnail = info.get("thumbnail") or ""
    thumbnails = info.get("thumbnails") or []
    if thumbnails:
        thumbnail = (thumbnails[-1] or {}).get("url") or thumbnail
    return json.dumps({
        "title": title,
        "artist": artist,
        "url": info.get("webpage_url") or url,
        "duration_seconds": int(info["duration"]) if info.get("duration") else None,
        "thumbnail": thumbnail,
        "view_count": info.get("view_count"),
        "like_count": info.get("like_count"),
    }, ensure_ascii=False)


# ── get_playlist_metadata ────────────────────────────────────────────────────

def get_playlist_metadata(url: str, cookie_file=None) -> str:
    """Return compact, ordered metadata for a public YouTube playlist."""
    opts = {
        "skip_download": True,
        "extract_flat": "in_playlist",
        "noplaylist": False,
        "playlistend": 1000,
    }
    info, _ = _extract_info(url, opts, cookie_file=cookie_file)
    if not isinstance(info, dict) or not info.get("entries"):
        raise RuntimeError("YouTube did not return readable playlist metadata")

    entries = []
    for entry in info.get("entries") or []:
        if not isinstance(entry, dict):
            continue
        entries.append({
            "id": entry.get("id") or "",
            "title": entry.get("title") or "",
            "uploader": (
                entry.get("uploader")
                or entry.get("channel")
                or entry.get("artist")
                or ""
            ),
            "url": entry.get("webpage_url") or entry.get("url") or "",
            "duration_seconds": (
                int(entry["duration"]) if entry.get("duration") is not None else None
            ),
        })

    return json.dumps({
        "title": info.get("title") or info.get("playlist_title") or "YouTube Playlist",
        "entries": entries,
    }, ensure_ascii=False)


def get_first_thumbnail(query: str, cookie_file=None) -> str:
    """Search YouTube and return the first result's thumbnail URL."""
    opts = {
        "extract_flat": False,
        "skip_download": True,
    }
    info, _ = _extract_info(f"ytsearch1:{query}", opts, cookie_file=cookie_file)

    entries = info.get("entries") or []
    first = entries[0] if entries else info
    thumbnail = first.get("thumbnail") or ""
    thumbnails = first.get("thumbnails") or []
    if thumbnails:
        best = thumbnails[-1]
        thumbnail = best.get("url") or thumbnail

    return json.dumps(
        {
            "title": first.get("title") or "",
            "artist": first.get("uploader") or first.get("channel") or "",
            "thumbnail": thumbnail,
        },
        ensure_ascii=False,
    )


# ── get_stream_url ─────────────────────────────────────────────────────────────

def _stream_payload(info, ydl):
    if not isinstance(info, dict):
        raise RuntimeError("YouTube returned invalid stream data")
    selected = info
    requested = info.get("requested_downloads") or []
    if requested and isinstance(requested[0], dict):
        selected = requested[0]
    stream_url = selected.get("url") or info.get("url")
    if not stream_url:
        formats = info.get("formats") or []
        if formats:
            selected = formats[-1] or {}
            stream_url = selected.get("url")
    if not stream_url:
        raise RuntimeError("YouTube returned no playable stream URL")

    raw_headers = selected.get("http_headers") or info.get("http_headers") or {}
    headers = {
        str(key): str(value)
        for key, value in raw_headers.items()
        if value is not None
    }
    cookie_jar = getattr(ydl, "cookiejar", None)
    if cookie_jar is not None and hasattr(cookie_jar, "get_cookie_header"):
        cookie_header = cookie_jar.get_cookie_header(stream_url)
        if cookie_header:
            headers["Cookie"] = str(cookie_header)
    return {"url": stream_url, "headers": headers}


def get_stream_data(url: str, cookie_file=None) -> str:
    """
    Return a URL that just_audio (ExoPlayer) can play and seek through.

    Priority:
      1. HLS manifest (.m3u8) — ExoPlayer handles seeking natively via
         the manifest's segment list. Best option for long tracks / podcasts.
      2. Direct m4a CDN URL — single-stream, supports HTTP range requests
         so ExoPlayer can seek by byte offset.
      3. Any bestaudio/best — last resort.

    We request the URL only (no download) using yt-dlp's get_url option.
    """
    # Prefer a single non-DRM audio stream. This may be a direct HTTPS URL or
    # HLS manifest; ExoPlayer handles both. Do not filter to protocol^=http,
    # because that rejects valid m3u8_native streams before ExoPlayer sees them.
    last_error = None
    for fmt in [
        "bestaudio[has_drm!=true]/best[has_drm!=true]",
        "bestaudio/best",
    ]:
        opts = {
            "skip_download": True,
            "format": fmt,
            "no_playlist": True,
        }
        try:
            payload, _ = _extract_info(
                url,
                opts,
                cookie_file=cookie_file,
                transform=_stream_payload,
            )
            return json.dumps(payload, ensure_ascii=False)
        except Exception as error:
            last_error = error

    raise last_error or RuntimeError(f"Could not resolve stream URL for: {url}")


def get_stream_url(url: str, cookie_file=None) -> str:
    """Compatibility wrapper for older native callers and bridge tests."""
    return json.loads(get_stream_data(url, cookie_file))["url"]


def test_access(url: str, cookie_file) -> str:
    if not cookie_file:
        raise RuntimeError("No YouTube cookies are configured")
    info, _ = _extract_info(
        url,
        {"skip_download": True, "no_playlist": True},
        cookie_file=cookie_file,
    )
    video_id = None
    if isinstance(info, dict):
        entries = info.get("entries") or []
        if entries:
            first = next((entry for entry in entries if isinstance(entry, dict)), None)
            video_id = first.get("id") if first else None
        else:
            video_id = info.get("id")
    if not video_id:
        raise RuntimeError("YouTube did not return a valid video during the access test")
    return json.dumps({"ok": True, "id": str(video_id)}, ensure_ascii=False)


# ── download ───────────────────────────────────────────────────────────────────

def download(url: str, output_dir: str, event_sink, cookie_file=None) -> None:
    """
    Download audio to output_dir, reporting progress via event_sink.

    event_sink.success(msg) is called with:
      "progress:<percent>:<message>"
      "track-json:<base64 UTF-8 JSON payload>"
      "done"
      "error:<message>"
    """
    import os
    from urllib.request import Request, urlopen

    def unicode_text(value) -> str:
        """Normalize downloader/filesystem values without dropping Unicode."""
        if value is None:
            return ""
        if isinstance(value, bytes):
            try:
                return value.decode("utf-8")
            except UnicodeDecodeError:
                # Some extractors/device code pages still surface legacy bytes.
                # Latin-1 is a lossless byte mapping and is preferable to either
                # throwing or stripping non-ASCII characters.
                return value.decode("latin-1")
        text = str(value)
        return text.encode("utf-8", errors="replace").decode("utf-8")

    def track_event(filepath, title, artist, cover_path, video_id) -> str:
        payload = {
            "path": unicode_text(filepath),
            "title": unicode_text(title),
            "artist": unicode_text(artist),
            "coverPath": unicode_text(cover_path),
            "videoId": unicode_text(video_id),
        }
        encoded = base64.b64encode(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        return f"track-json:{encoded}"

    output_template = os.path.join(output_dir, "%(title)s.%(ext)s")

    current_item = [1]
    total_items = [1]

    def progress_hook(d):
        status = d.get("status")
        if status == "downloading":
            pct_str = d.get("_percent_str", "0%").strip().replace("%", "")
            try:
                pct = float(pct_str)
            except ValueError:
                pct = 0.0
            prefix = (
                f"({current_item[0]}/{total_items[0]}) "
                if total_items[0] > 1
                else ""
            )
            msg = f"progress:{pct:.1f}:{prefix}Downloading... {pct:.1f}%"
            event_sink.success(msg)
        elif status == "finished":
            prefix = (
                f"({current_item[0]}/{total_items[0]}) "
                if total_items[0] > 1
                else ""
            )
            event_sink.success(f"progress:99.0:{prefix}Processing audio...")
            filepath = unicode_text(os.fsdecode(
                d.get("filename") or d.get("info_dict", {}).get("filepath", "")
            ))
            info = d.get("info_dict", {})
            if filepath:
                title = info.get("title") or ""
                artist = info.get("uploader") or info.get("channel") or info.get("artist") or ""
                video_id = info.get("id") or ""
                cover_path = ""
                thumbnail_url = info.get("thumbnail")
                if thumbnail_url:
                    try:
                        cover_path = filepath + ".cover"
                        request = Request(thumbnail_url, headers={"User-Agent": "Mozilla/5.0"})
                        with urlopen(request, timeout=20) as response, open(cover_path, "wb") as cover:
                            cover.write(response.read())
                    except Exception:
                        cover_path = ""
                event_sink.success(track_event(filepath, title, artist, cover_path, video_id))
                current_item[0] += 1

    def postprocessor_hook(d):
        if d.get("status") == "finished":
            filepath = d.get("info_dict", {}).get("filepath") or d.get("filepath", "")
            if not filepath:
                return
            info = d.get("info_dict", {})
            title = info.get("title") or ""
            artist = (
                info.get("uploader")
                or info.get("channel")
                or info.get("artist")
                or ""
            )
            event_sink.success(track_event(filepath, title, artist, "", info.get("id") or ""))
            current_item[0] += 1

    opts = {
        # Prefer a directly downloadable audio file. HLS/DASH merging would
        # make yt-dlp look for an external ffmpeg binary, which does not exist
        # in the Android Python runtime; Flutter converts the result afterward.
        "format": "bestaudio[has_drm!=true]/best[has_drm!=true]",
        "outtmpl": output_template,
        "progress_hooks": [progress_hook],
        # Keep valid Unicode. yt-dlp still replaces only separators/control
        # characters which are actually invalid for the target filesystem.
        "restrictfilenames": False,
        "windowsfilenames": False,
        # Conversion is handled by the app's bundled FFmpegKit library.
        # Never ask yt-dlp to locate desktop ffmpeg/ffprobe executables on Android.
        "yes_playlist": True,
    }

    try:
        info, _ = _extract_info(url, opts, download=True, cookie_file=cookie_file)
        entries = info.get("entries") if info else None
        if entries:
            total_items[0] = len(list(entries))
        event_sink.success("done")
    except Exception as e:
        event_sink.success(f"error:{unicode_text(e)}")
