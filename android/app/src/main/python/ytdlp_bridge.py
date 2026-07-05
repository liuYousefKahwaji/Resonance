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

import json
import yt_dlp


# ── Shared yt-dlp options ──────────────────────────────────────────────────────

_BASE_OPTS = {
    "quiet": True,
    "no_warnings": True,
    "extractor_retries": 3,
    "socket_timeout": 20,
}


def _make_ydl(extra=None):
    opts = dict(_BASE_OPTS)
    if extra:
        opts.update(extra)
    return yt_dlp.YoutubeDL(opts)


# ── search ─────────────────────────────────────────────────────────────────────

def search(query: str) -> str:
    """Return JSON array of up to 5 search results."""
    opts = {
        **_BASE_OPTS,
        "extract_flat": True,
        "skip_download": True,
    }
    with _make_ydl(opts) as ydl:
        info = ydl.extract_info(f"ytsearch5:{query}", download=False)

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
        results.append({
            "title": title,
            "uploader": uploader,
            "url": url,
            "duration_seconds": int(duration) if duration else None,
        })

    return json.dumps(results, ensure_ascii=False)


# ── get_metadata ───────────────────────────────────────────────────────────────

def get_metadata(url: str) -> str:
    """Return JSON object with title and artist for a single video."""
    opts = {
        **_BASE_OPTS,
        "skip_download": True,
        "extract_flat": False,
    }
    with _make_ydl(opts) as ydl:
        info = ydl.extract_info(url, download=False)

    title = info.get("title") or "Streaming Track"
    artist = (
        info.get("uploader")
        or info.get("channel")
        or info.get("uploader_id")
        or "YouTube"
    )
    return json.dumps({"title": title, "artist": artist}, ensure_ascii=False)


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
    # Try HLS first
    for fmt in [
        "hls/bestaudio[ext=m4a]/bestaudio/best",
        "bestaudio[ext=m4a]/bestaudio/best",
    ]:
        opts = {
            **_BASE_OPTS,
            "skip_download": True,
            "format": fmt,
            "get_url": True,          # print URL only, very fast
            "no_playlist": True,
        }
        try:
            with _make_ydl(opts) as ydl:
                info = ydl.extract_info(url, download=False)

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
      "track:<filepath>|<title_encoded>|<artist_encoded>"
      "done"
      "error:<message>"
    """
    import os
    from urllib.parse import quote

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
            encoded = (
                f"track:{filepath}"
                f"|{quote(title, safe='')}"
                f"|{quote(artist, safe='')}"
            )
            event_sink.success(encoded)
            current_item[0] += 1

    opts = {
        **_BASE_OPTS,
        "format": "bestaudio/best",
        "outtmpl": output_template,
        "progress_hooks": [progress_hook],
        "postprocessor_hooks": [postprocessor_hook],
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            },
            {"key": "EmbedThumbnail"},
            {"key": "FFmpegMetadata"},
        ],
        "writethumbnail": False,
        "yes_playlist": True,
    }

    try:
        with _make_ydl(opts) as ydl:
            info = ydl.extract_info(url, download=True)
            entries = info.get("entries") if info else None
            if entries:
                total_items[0] = len(list(entries))
        event_sink.success("done")
    except Exception as e:
        event_sink.success(f"error:{e}")