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
import yt_dlp


# ── Shared yt-dlp options ──────────────────────────────────────────────────────

_BASE_OPTS = {
    "quiet": True,
    "no_warnings": True,
    "extractor_retries": 3,
    "socket_timeout": 20,
}

# Let yt-dlp choose its maintained default clients first. Hard-coding
# web_embedded,tv_simply caused ordinary public videos to return no formats as
# YouTube changed its PO-token policy. android_vr remains a useful no-JavaScript
# fallback, while web_embedded covers videos which explicitly allow embedding.
_FALLBACK_EXTRACTOR_ARGS = {
    "youtube": {"player_client": ["android_vr", "web_embedded"]},
}


def _make_ydl(extra=None):
    opts = dict(_BASE_OPTS)
    if extra:
        opts.update(extra)
    return yt_dlp.YoutubeDL(opts)


def _extract_info(target, extra=None, download=False):
    """Extract with yt-dlp defaults, then one Android-safe client fallback."""
    attempts = [dict(extra or {})]
    fallback = dict(extra or {})
    fallback["extractor_args"] = _FALLBACK_EXTRACTOR_ARGS
    attempts.append(fallback)
    last_error = None
    for opts in attempts:
        try:
            with _make_ydl(opts) as ydl:
                return ydl.extract_info(target, download=download), ydl
        except Exception as error:
            last_error = error
    raise last_error or RuntimeError(f"Could not extract: {target}")


# ── search ─────────────────────────────────────────────────────────────────────

def search(query: str, limit: int = 10) -> str:
    """Return a JSON array capped to the requested search result count."""
    result_limit = max(1, min(int(limit), 10))
    opts = {
        "extract_flat": True,
        "skip_download": True,
    }
    info, _ = _extract_info(f"ytsearch{result_limit}:{query}", opts)

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
            "live_status": entry.get("live_status"),
            "availability": entry.get("availability"),
            "is_short": "/shorts/" in str(entry.get("original_url") or entry.get("webpage_url") or ""),
        })

    return json.dumps(results, ensure_ascii=False)


# ── get_metadata ───────────────────────────────────────────────────────────────

def get_metadata(url: str) -> str:
    """Return JSON object with title and artist for a single video."""
    opts = {
        "skip_download": True,
        "extract_flat": False,
    }
    info, _ = _extract_info(url, opts)

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
    }, ensure_ascii=False)


# ── get_playlist_metadata ────────────────────────────────────────────────────

def get_playlist_metadata(url: str) -> str:
    """Return compact, ordered metadata for a public YouTube playlist."""
    opts = {
        "skip_download": True,
        "extract_flat": "in_playlist",
        "noplaylist": False,
        "playlistend": 1000,
    }
    info, _ = _extract_info(url, opts)
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


def get_first_thumbnail(query: str) -> str:
    """Search YouTube and return the first result's thumbnail URL."""
    opts = {
        "extract_flat": False,
        "skip_download": True,
    }
    info, _ = _extract_info(f"ytsearch1:{query}", opts)

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

def get_stream_url(url: str) -> str:
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
            info, _ = _extract_info(url, opts)

            # When get_url=True, the url is in info["url"] or the first format
            stream_url = None
            if isinstance(info, dict):
                stream_url = info.get("url")
                if not stream_url:
                    fmts = info.get("formats") or []
                    if fmts:
                        stream_url = fmts[-1].get("url")

            if stream_url:
                return stream_url
        except Exception:
            continue

    raise RuntimeError(f"Could not resolve stream URL for: {url}")


# ── download ───────────────────────────────────────────────────────────────────

def download(url: str, output_dir: str, event_sink) -> None:
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
        info, _ = _extract_info(url, opts, download=True)
        entries = info.get("entries") if info else None
        if entries:
            total_items[0] = len(list(entries))
        event_sink.success("done")
    except Exception as e:
        event_sink.success(f"error:{unicode_text(e)}")
