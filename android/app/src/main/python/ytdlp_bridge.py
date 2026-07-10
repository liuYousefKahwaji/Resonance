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


def get_first_thumbnail(query: str) -> str:
    """Search YouTube and return the first result's thumbnail URL."""
    opts = {
        **_BASE_OPTS,
        "extract_flat": False,
        "skip_download": True,
    }
    with _make_ydl(opts) as ydl:
        info = ydl.extract_info(f"ytsearch1:{query}", download=False)

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
      "track:<filepath>|<title_encoded>|<artist_encoded>|<cover_encoded>|<video_id>"
      "done"
      "error:<message>"
    """
    import os
    from urllib.request import Request, urlopen
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
            filepath = os.fsdecode(
                d.get("filename") or d.get("info_dict", {}).get("filepath", "")
            )
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
                event_sink.success(
                    f"track:{filepath}|{quote(title, safe='')}|{quote(artist, safe='')}"
                    f"|{quote(cover_path, safe='')}|{quote(video_id, safe='')}"
                )
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
            encoded = (
                f"track:{filepath}"
                f"|{quote(title, safe='')}"
                f"|{quote(artist, safe='')}"
            )
            event_sink.success(encoded)
            current_item[0] += 1

    opts = {
        **_BASE_OPTS,
        # Prefer a directly downloadable audio file. HLS/DASH merging would
        # make yt-dlp look for an external ffmpeg binary, which does not exist
        # in the Android Python runtime; Flutter converts the result afterward.
        "format": "bestaudio[protocol^=http][vcodec=none]/bestaudio[protocol^=http]/best[protocol^=http]",
        "outtmpl": output_template,
        "progress_hooks": [progress_hook],
        # Conversion is handled by the app's bundled FFmpegKit library.
        # Never ask yt-dlp to locate desktop ffmpeg/ffprobe executables on Android.
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
