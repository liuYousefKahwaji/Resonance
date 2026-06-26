"""
ytdlp_bridge.py
---------------
Called from Kotlin via Chaquopy. All functions return plain Python
dicts/lists which Chaquopy auto-converts to Java/Kotlin types.

Progress is reported by calling back into Kotlin via the `callback`
object passed in — Chaquopy lets Python call Java interfaces directly.
"""

import json
import sys
import yt_dlp


def search(query: str) -> list:
    """
    Search YouTube for `query`, return up to 5 results.
    Each result is a dict: {title, uploader, url, duration_seconds}
    """
    results = []

    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "skip_download": True,
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(f"ytsearch5:{query}", download=False)
        if info and "entries" in info:
            for entry in info["entries"]:
                if entry is None:
                    continue
                results.append({
                    "title": entry.get("title") or "Unknown",
                    "uploader": entry.get("uploader") or entry.get("channel") or "Unknown",
                    "url": entry.get("webpage_url") or entry.get("url") or "",
                    "duration_seconds": entry.get("duration"),
                })

    return results


def download(url: str, output_dir: str, event_sink) -> None:
    """
    Download audio for `url` to `output_dir`.
    Reports progress by calling event_sink.success(str) with:
      "progress:<percent>:<message>"
      "track:<filepath>"
      "done"
      "error:<message>"
    """

    current_item = [1]
    total_items = [1]
    processed = set()

    def progress_hook(d):
        status = d.get("status")
        if status == "downloading":
            # yt-dlp gives _percent_str like " 42.3%" or downloaded/total bytes
            pct_str = d.get("_percent_str", "").strip().replace("%", "")
            try:
                pct = float(pct_str)
            except ValueError:
                downloaded = d.get("downloaded_bytes", 0) or 0
                total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                pct = (downloaded / total * 100.0) if total > 0 else 0.0

            prefix = f"({current_item[0]}/{total_items[0]}) " if total_items[0] > 1 else ""
            msg = f"progress:{pct:.1f}:{prefix}Downloading... {pct:.1f}%"
            event_sink.success(msg)

        elif status == "finished":
            prefix = f"({current_item[0]}/{total_items[0]}) " if total_items[0] > 1 else ""
            event_sink.success(f"progress:99.0:{prefix}Processing audio...")

    import os

    output_template = os.path.join(output_dir, "%(title)s.%(ext)s")

    ydl_opts = {
        "format": "bestaudio/best",
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "192",
        }],
        "outtmpl": output_template,
        "progress_hooks": [progress_hook],
        "quiet": True,
        "no_warnings": True,
        "noplaylist": False,
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            # Single-pass: download and get info together.
            # The double-call (download=False then download=True) hit the
            # network twice and could return mismatched entry sets.
            info = ydl.extract_info(url, download=True)

            # Set playlist size from the downloaded result
            if info and info.get("_type") == "playlist":
                entries = [e for e in (info.get("entries") or []) if e]
                total_items[0] = len(entries)

            # Collect finished filepaths
            def collect_paths(info_dict, item_index=1):
                if info_dict is None:
                    return
                if info_dict.get("_type") == "playlist":
                    for idx, entry in enumerate(info_dict.get("entries") or [], start=1):
                        current_item[0] = idx
                        collect_paths(entry, idx)
                else:
                    # Resolve the final filename after post-processing
                    filepath = info_dict.get("requested_downloads", [{}])[0].get("filepath")
                    if not filepath:
                        # Fallback: reconstruct from template
                        filepath = ydl.prepare_filename(info_dict)
                        # Swap extension to .mp3
                        base, _ = os.path.splitext(filepath)
                        filepath = base + ".mp3"
                    if filepath and filepath not in processed:
                        if os.path.exists(filepath):
                            processed.add(filepath)
                            event_sink.success(f"track:{filepath}")

            collect_paths(info)

        event_sink.success("done")

    except Exception as e:
        event_sink.success(f"error:{str(e)}")
