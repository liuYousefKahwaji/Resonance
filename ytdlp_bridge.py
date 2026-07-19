"""
ytdlp_bridge.py
---------------
Called from Kotlin via Chaquopy. All functions return plain Python
dicts/lists which Chaquopy auto-converts to Java/Kotlin types.

Progress is reported by calling back into Kotlin via the `event_sink`
object passed in — Chaquopy lets Python call Kotlin objects directly.

Android-specific: FFmpeg is NOT available, so we download natively
(m4a/webm/opus). No postprocessors are used. just_audio handles m4a
and webm/opus fine on Android without conversion.
"""

import json
import os
import yt_dlp

_YOUTUBE_FALLBACK_EXTRACTOR_ARGS = {
    "youtube": {"player_client": ["android_vr", "web_embedded"]},
}


def _extract_info(target, options, download=False):
    """Use yt-dlp's maintained defaults before an Android-safe fallback."""
    attempts = [dict(options), {**options, "extractor_args": _YOUTUBE_FALLBACK_EXTRACTOR_ARGS}]
    last_error = None
    for attempt in attempts:
        try:
            with yt_dlp.YoutubeDL(attempt) as ydl:
                return ydl.extract_info(target, download=download), ydl
        except Exception as error:
            last_error = error
    raise last_error or RuntimeError(f"Could not extract: {target}")


def search(query: str) -> str:
    """
    Search YouTube for `query`, return up to 5 results as a JSON string.
    JSON avoids fragile PyObject dict conversion on the Kotlin side.
    """
    results = []

    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": "in_playlist",
        "skip_download": True,
        "default_search": "ytsearch",
    }

    info, _ = _extract_info(f"ytsearch10:{query}", ydl_opts)
    if info and "entries" in info:
        for entry in info["entries"]:
            if entry is None:
                continue
            # duration may be None for some entries — keep it as None,
            # Kotlin handles None → null via Integer boxing.
            duration = entry.get("duration")
            video_id = entry.get("id") or entry.get("url") or ""
            webpage_url = entry.get("webpage_url")
            if not webpage_url and video_id and not str(video_id).startswith("http"):
                webpage_url = f"https://www.youtube.com/watch?v={video_id}"

            results.append({
                "title":            entry.get("title") or "Unknown",
                "uploader":         entry.get("uploader") or entry.get("channel") or "Unknown",
                "url":              webpage_url or entry.get("url") or "",
                "duration_seconds": int(duration) if duration is not None else None,
                "thumbnail": entry.get("thumbnail") or "",
                "live_status": entry.get("live_status"),
                "availability": entry.get("availability"),
                "is_short": "/shorts/" in str(entry.get("original_url") or entry.get("webpage_url") or ""),
            })

    return json.dumps(results)


def download(url: str, output_dir: str, event_sink) -> None:
    """
    Download audio for `url` to `output_dir`.

    NO ffmpeg/ffprobe required — downloads best native audio (m4a preferred,
    falls back to webm/opus). just_audio on Android plays all these natively.

    Reports progress via event_sink.success(str):
      "progress:<percent>:<message>"   – 0.0–100.0
      "track:<filepath>"               – one per downloaded track
      "done"
      "error:<message>"
    """

    current_item = [1]
    total_items  = [1]
    processed    = set()

    def progress_hook(d):
        status = d.get("status")
        if status == "downloading":
            # ── Try percentage first ────────────────────────────────────────
            pct = None
            pct_str = d.get("_percent_str", "").strip().rstrip("%")
            try:
                pct = float(pct_str)
            except (ValueError, TypeError):
                pass

            # ── Fragment-based fallback (HLS / DASH / YouTube adaptive) ────
            # YouTube almost always uses fragmented delivery, where
            # _percent_str is "0.0%" throughout because total bytes are
            # unknown. Fragment index gives reliable progress instead.
            if pct is None or pct == 0.0:
                frag_index = d.get("fragment_index")
                frag_count = d.get("fragment_count")
                if frag_index and frag_count and frag_count > 0:
                    pct = (frag_index / frag_count) * 100.0
                else:
                    # Last resort: bytes ratio
                    downloaded = d.get("downloaded_bytes") or 0
                    total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                    pct = (downloaded / total * 100.0) if total > 0 else 0.0

            prefix = f"({current_item[0]}/{total_items[0]}) " if total_items[0] > 1 else ""
            event_sink.success(f"progress:{pct:.1f}:{prefix}Downloading... {pct:.1f}%")

        elif status == "finished":
            prefix = f"({current_item[0]}/{total_items[0]}) " if total_items[0] > 1 else ""
            event_sink.success(f"progress:99.0:{prefix}Finalizing...")

    output_template = os.path.join(output_dir, "%(title)s.%(ext)s")

    base_opts = {
        "outtmpl": output_template,
        "progress_hooks": [progress_hook],
        "quiet": True,
        "no_warnings": True,
        "noplaylist": False,
        # Embed available metadata without ffmpeg (only works for some containers)
        "writethumbnail": False,
        "postprocessors": [],   # explicitly empty — no ffmpeg steps
        "format": "bestaudio[has_drm!=true]/best[has_drm!=true]",
    }

    attempts = [
        {
            **base_opts,
            # Let yt-dlp choose. This avoids Android/Web client format bugs
            # where even "best" is reported unavailable.
        },
        {**base_opts},
    ]

    try:
        info = None
        last_error = None
        active_ydl = None

        for ydl_opts in attempts:
            try:
                info, active_ydl = _extract_info(url, ydl_opts, download=True)
                break
            except Exception as e:
                last_error = e

        if info is None or active_ydl is None:
            raise last_error or Exception("Download failed")

        # Update playlist size from actual result
        if info and info.get("_type") == "playlist":
            entries = [e for e in (info.get("entries") or []) if e]
            total_items[0] = len(entries)

        def collect_paths(info_dict, item_index=1):
            if info_dict is None:
                return
            if info_dict.get("_type") == "playlist":
                for idx, entry in enumerate(info_dict.get("entries") or [], start=1):
                    current_item[0] = idx
                    collect_paths(entry, idx)
            else:
                filepath = None
                requested = info_dict.get("requested_downloads") or []
                if requested:
                    filepath = requested[0].get("filepath")
                if not filepath:
                    filepath = active_ydl.prepare_filename(info_dict)
                if filepath and filepath not in processed and os.path.exists(filepath):
                    processed.add(filepath)
                    event_sink.success(f"track:{filepath}")

        collect_paths(info)

        event_sink.success("done")

    except Exception as e:
        event_sink.success(f"error:{str(e)}")


def get_stream_url(url: str) -> str:
    """
    Extract the direct media stream URL for the given video/audio link.
    """
    ydl_opts = {
        "format": "bestaudio[has_drm!=true]/best[has_drm!=true]",
        "quiet": True,
        "no_warnings": True,
    }
    info, _ = _extract_info(url, ydl_opts)
    return info.get("url") or ""


def get_metadata(url: str) -> str:
    """
    Extract title and artist metadata for a URL without downloading.
    """
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
    }
    info, _ = _extract_info(url, ydl_opts)
    return json.dumps({
        "title": info.get("title") or "Streaming Track",
        "artist": info.get("uploader") or info.get("channel") or "YouTube"
    })
