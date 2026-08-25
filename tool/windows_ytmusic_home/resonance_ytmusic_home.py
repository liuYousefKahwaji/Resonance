"""Small Windows-only YouTube Music home helper.

The executable receives only a browser id and a shelf limit. Browser cookies are
read in memory and are never written to stdout, disk, or Flutter.
"""

import argparse
import http.cookiejar
import json
import sys
import urllib.request

from yt_dlp.cookies import extract_cookies_from_browser
from ytmusicapi import YTMusic
from ytmusicapi.helpers import get_authorization


# PyInstaller inherits the active Windows code page for redirected pipes.
# Personalized shelf titles frequently contain characters outside that code
# page, so force the helper contract to UTF-8 before emitting JSON/errors.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


class _Logger:
    def debug(self, _message):
        pass

    def info(self, _message):
        pass

    def warning(self, message):
        print(str(message), file=sys.stderr)

    def error(self, message):
        print(str(message), file=sys.stderr)


_SUPPORTED_BROWSERS = {
    "edge",
    "chrome",
    "firefox",
    "brave",
    "vivaldi",
    "opera",
    "chromium",
    "whale",
}


def _browser_parts(browser_source):
    browser, separator, profile = (browser_source or "").partition(":")
    browser = browser.strip().lower()
    profile = profile.strip() if separator else None
    if browser not in _SUPPORTED_BROWSERS:
        raise RuntimeError("The selected browser is not supported")
    if profile and (profile in (".", "..") or any(token in profile for token in ("/", "\\", ":"))):
        raise RuntimeError("The selected browser profile is invalid")
    return browser, profile or None


def _cookie_header_from_jar(jar):
    # Let CookieJar apply domain, path, secure, and expiry rules for the exact
    # YouTube Music endpoint. Iterating the whole jar can mix cookies from
    # Google account pages or duplicate cookies from unrelated paths.
    request = urllib.request.Request("https://music.youtube.com/youtubei/v1/browse")
    jar.add_cookie_header(request)
    cookie = request.get_header("Cookie") or ""
    if not cookie.strip():
        raise RuntimeError("No YouTube Music cookies were found in the selected browser profile")
    return cookie


def _cookie_header(browser_source, cookie_file):
    if cookie_file:
        jar = http.cookiejar.MozillaCookieJar(cookie_file)
        jar.load(ignore_discard=True, ignore_expires=True)
    else:
        browser, profile = _browser_parts(browser_source)
        jar = extract_cookies_from_browser(browser, profile=profile, logger=_Logger())
    return _cookie_header_from_jar(jar)


def _auth_headers(cookie, auth_user="0"):
    sapisid = next((part.split("=", 1)[1] for part in cookie.split("; ") if part.startswith("__Secure-3PAPISID=")), None)
    if not sapisid:
        raise RuntimeError("The YouTube session is missing its authenticated SAPISID cookie")
    origin = "https://music.youtube.com"
    return {
        "accept": "*/*",
        "content-type": "application/json",
        "cookie": cookie,
        "origin": origin,
        "x-origin": origin,
        "x-goog-authuser": str(auth_user),
        "authorization": get_authorization(sapisid + " " + origin),
    }


def _thumbnail(item, video_id=None):
    """Read ytmusicapi's thumbnail variants, with a stable video fallback."""
    direct = item.get("thumbnail")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    if isinstance(direct, dict) and direct.get("url"):
        return str(direct["url"])
    thumbs = item.get("thumbnails") or []
    for thumb in reversed(thumbs):
        if isinstance(thumb, dict) and thumb.get("url"):
            return str(thumb["url"])
    if video_id:
        return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"
    return ""


def _track(item):
    if not isinstance(item, dict):
        return None
    video_id = item.get("videoId")
    if not video_id or len(str(video_id)) != 11:
        return None
    artists = item.get("artists") or []
    artist = (artists[0].get("name") if artists and isinstance(artists[0], dict) else None) or "Unknown"
    thumbnail = _thumbnail(item, str(video_id))
    return {
        "title": str(item.get("title") or "Unknown"),
        "artist": str(artist),
        "url": f"https://www.youtube.com/watch?v={video_id}",
        "duration_seconds": item.get("duration_seconds"),
        "thumbnail": thumbnail,
    }


def _item(item):
    if not isinstance(item, dict):
        return None
    track = _track(item)
    artists = item.get("artists") or []
    subtitle = " · ".join(
        str(artist.get("name")) for artist in artists if isinstance(artist, dict) and artist.get("name")
    )
    kind = str(item.get("resultType") or item.get("type") or ("track" if track else "collection"))
    if not subtitle and kind.lower() not in ("track", "collection"):
        subtitle = kind
    thumbnail = track["thumbnail"] if track else _thumbnail(item)
    title = str(item.get("title") or "").strip()
    if not title:
        return None
    playlist_id = item.get("audioPlaylistId") or item.get("playlistId")
    return {
        "title": title,
        "subtitle": subtitle,
        "thumbnail": thumbnail,
        "kind": kind,
        "track": track,
        "playlistId": str(playlist_id) if playlist_id else None,
        "browseId": str(item.get("browseId")) if item.get("browseId") else None,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser")
    parser.add_argument("--cookies-file")
    parser.add_argument("--limit", type=int, default=12)
    args = parser.parse_args()
    if not args.browser and not args.cookies_file:
        parser.error("one of --browser or --cookies-file is required")
    cookie = _cookie_header(args.browser, args.cookies_file)
    ytmusic = YTMusic(auth=_auth_headers(cookie), language="en")
    # get_home is also available to guest clients. Confirm an authenticated-only
    # endpoint first so a rejected/wrong profile can never masquerade as a
    # successful generic Home response.
    account = ytmusic.get_account_info()
    if not isinstance(account, dict) or not account.get("accountName"):
        raise RuntimeError("The selected browser profile is not signed in to YouTube Music")
    home = ytmusic.get_home(limit=max(1, min(args.limit, 80))) or []
    shelves = []
    for shelf in home:
        tracks = []
        items = []
        for item in shelf.get("contents") or []:
            track = _track(item)
            if track and track not in tracks:
                tracks.append(track)
            normalized_item = _item(item)
            if normalized_item and normalized_item not in items:
                items.append(normalized_item)
        title = str(shelf.get("title") or "").strip()
        if title and items:
            shelves.append({"title": title, "tracks": tracks, "items": items})
    # Quick picks is the most useful personalized row and YouTube Music places
    # it prominently in its native clients. Keep it first even when the API
    # happens to return it after other continuation rows.
    shelves.sort(key=lambda shelf: 0 if "quick pick" in shelf["title"].lower() else 1)

    history_tracks = []
    try:
        for history_item in ytmusic.get_history() or []:
            track = _track(history_item)
            if track and track not in history_tracks:
                history_tracks.append(track)
    except Exception:
        # Home itself remains useful when history is unavailable or disabled.
        pass
    existing_playable = []
    for shelf in shelves:
        for track in shelf["tracks"]:
            if track not in existing_playable:
                existing_playable.append(track)
    fallback_tracks = []
    if not history_tracks and len(existing_playable) < 20:
        resolution_attempts = 0
        for shelf in home:
            for item in shelf.get("contents") or []:
                try:
                    playlist_id = item.get("playlistId") or item.get("audioPlaylistId")
                    if playlist_id:
                        resolution_attempts += 1
                        resolved = (ytmusic.get_playlist(playlist_id, limit=20) or {}).get("tracks") or []
                    elif item.get("browseId"):
                        resolution_attempts += 1
                        resolved = (ytmusic.get_album(item["browseId"]) or {}).get("tracks") or []
                    else:
                        continue
                    for resolved_item in resolved:
                        track = _track(resolved_item)
                        if track and track not in fallback_tracks:
                            fallback_tracks.append(track)
                except Exception:
                    continue
                if len(fallback_tracks) >= 20 or resolution_attempts >= 6:
                    break
            if len(fallback_tracks) >= 20 or resolution_attempts >= 6:
                break
    pick_source = history_tracks or (existing_playable + [track for track in fallback_tracks if track not in existing_playable])
    if pick_source and not any("quick pick" in shelf["title"].lower() for shelf in shelves):
        picks = pick_source[:20]
        pick_items = [
            {"title": track["title"], "subtitle": track["artist"], "thumbnail": track["thumbnail"], "kind": "track", "track": track}
            for track in picks
        ]
        shelves.insert(0, {"title": "Quick picks", "tracks": picks, "items": pick_items})

    # Some accounts do not expose a literally named Suggestions row. Build one
    # from the personalized feed without inventing recommendations or exposing
    # raw response data. This also gives Resonance a stable, queueable section.
    if not any("suggest" in shelf["title"].lower() for shelf in shelves):
        seen = set()
        suggestions = []
        seed = next((track for shelf in shelves for track in shelf["tracks"]), None)
        if seed:
            try:
                video_id = seed["url"].split("v=", 1)[1].split("&", 1)[0]
                for item in (ytmusic.get_watch_playlist(videoId=video_id, radio=True, limit=25) or {}).get("tracks") or []:
                    track = _track(item)
                    if track and track["url"] != seed["url"] and track["url"] not in seen:
                        seen.add(track["url"])
                        suggestions.append(track)
                    if len(suggestions) >= 20:
                        break
            except Exception:
                pass
        for shelf in shelves:
            if "quick pick" in shelf["title"].lower():
                continue
            for track in shelf["tracks"]:
                if track["url"] not in seen:
                    seen.add(track["url"])
                    suggestions.append(track)
                if len(suggestions) >= 20:
                    break
            if len(suggestions) >= 20:
                break
        if suggestions:
            suggestions = suggestions[:20]
            suggestion_items = [
                {"title": track["title"], "subtitle": track["artist"], "thumbnail": track["thumbnail"], "kind": "track", "track": track}
                for track in suggestions
            ]
            shelves.insert(1 if shelves else 0, {"title": "Suggestions", "tracks": suggestions, "items": suggestion_items})

    speed_dial = []
    seen_speed_dial = set()
    for shelf in shelves:
        if any(token in shelf["title"].lower() for token in ("listen again", "forgotten", "quick pick")):
            for track in shelf["tracks"]:
                if track["url"] not in seen_speed_dial:
                    seen_speed_dial.add(track["url"])
                    speed_dial.append(track)
                if len(speed_dial) >= 12:
                    break
        if len(speed_dial) >= 12:
            break
    for track in pick_source:
        if track["url"] not in seen_speed_dial:
            seen_speed_dial.add(track["url"])
            speed_dial.append(track)
        if len(speed_dial) >= 12:
            break
    if speed_dial and not any("speed dial" in shelf["title"].lower() for shelf in shelves):
        speed_items = [
            {"title": track["title"], "subtitle": track["artist"], "thumbnail": track["thumbnail"], "kind": "track", "track": track}
            for track in speed_dial
        ]
        shelves.insert(min(2, len(shelves)), {"title": "Speed dial", "tracks": speed_dial, "items": speed_items})

    print(json.dumps({"shelves": shelves}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
