"""User-authorized Chromium YouTube cookie bridge. No browser DB decryption.

Native messaging only accepts the bundled extension. Durable snapshots use
Windows current-user DPAPI; the normal Music helper consumes them in memory.
yt-dlp receives a short-lived, app-private Netscape file removed by its caller.
"""
import argparse
import ctypes
from ctypes import wintypes
from contextlib import contextmanager
import http.cookiejar
import json
import math
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import time

EXTENSION_ID = "ijekcmdjbphddbjhkedmhjaampmjaogp"
ORIGIN = f"chrome-extension://{EXTENSION_ID}/"
HOST_NAME = "com.resonance.youtube"
MAX_BYTES = 1024 * 1024
SOURCE = re.compile(r"^(chrome|edge|brave|vivaldi|opera|chromium|whale)\+connector:([a-f0-9]{32})$")


def root():
    return Path(os.environ["LOCALAPPDATA"]) / "Resonance" / "BrowserConnector"


def source_parts(source):
    match = SOURCE.fullmatch(source or "")
    if not match:
        raise RuntimeError("Reconnect the browser session in Resonance.")
    return match.groups()


@contextmanager
def locked():
    import msvcrt
    directory = root()
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "session.lock").open("a+b") as stream:
        stream.write(b"0")
        stream.flush()
        deadline = time.monotonic() + 5
        while True:
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The browser connector is busy. Try again.") from None
                time.sleep(0.05)
        try:
            yield
        finally:
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def atomic_write(path, data):
    handle, name = tempfile.mkstemp(dir=path.parent, prefix="pending-")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def protect(data, decrypt=False):
    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]
    buffer = ctypes.create_string_buffer(data)
    incoming = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    outgoing = Blob()
    crypto = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if decrypt:
        operation = crypto.CryptUnprotectData
        operation.argtypes = [ctypes.POINTER(Blob), ctypes.POINTER(wintypes.LPWSTR), ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        args = [ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)]
    else:
        operation = crypto.CryptProtectData
        operation.argtypes = [ctypes.POINTER(Blob), wintypes.LPCWSTR, ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        args = [ctypes.byref(incoming), "Resonance YouTube session", None, None, None, 1, ctypes.byref(outgoing)]
    operation.restype = wintypes.BOOL
    if not operation(*args):
        raise RuntimeError("Windows could not unlock the browser session. Reconnect in Resonance.")
    try:
        return ctypes.string_at(outgoing.data, outgoing.size)
    finally:
        kernel.LocalFree(outgoing.data)


def permit(source):
    browser, ticket = source_parts(source)
    path = root() / f"{ticket}.permit.json"
    try:
        info = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise RuntimeError("Start Connect browser session in Resonance first.") from None
    if info.get("browser") != browser or info.get("state") not in ("pending", "active"):
        raise RuntimeError("Start Connect browser session in Resonance first.")
    if info["state"] == "pending" and not 0 <= time.time() - info.get("created", 0) < 600:
        raise RuntimeError("Connection expired. Start Connect browser session again.")
    return info


def normalized_cookies(cookies):
    if not isinstance(cookies, list) or len(cookies) > 512:
        raise RuntimeError("Invalid YouTube session. Reconnect in Resonance.")
    result = []
    for cookie in cookies:
        if not isinstance(cookie, dict):
            raise RuntimeError("Invalid YouTube session.")
        domain = str(cookie.get("domain", "")).lower()
        host = domain.lstrip(".")
        if host != "youtube.com" and not host.endswith(".youtube.com"):
            raise RuntimeError("Only YouTube cookies can be connected.")
        name, value, path = (cookie.get(key, default) for key, default in [("name", ""), ("value", ""), ("path", "/")])
        if any(not isinstance(part, str) or any(c in part for c in "\t\r\n\0") for part in (domain, name, value, path)) or not name or not path.startswith("/"):
            raise RuntimeError("Invalid YouTube session.")
        expires = cookie.get("expirationDate")
        if expires is not None:
            if isinstance(expires, bool) or not isinstance(expires, (int, float)) or not math.isfinite(expires) or not 0 <= expires < 2 ** 63:
                raise RuntimeError("Invalid cookie expiry.")
            expires = int(expires)
            if expires <= time.time():
                continue
        result.append({"domain": domain, "name": name, "value": value, "path": path, "secure": cookie.get("secure") is True, "httpOnly": cookie.get("httpOnly") is True, "expirationDate": expires})
    if len(json.dumps(result).encode("utf-8")) > MAX_BYTES:
        raise RuntimeError("YouTube session is too large.")
    return result


def signed_in(cookies):
    names = {c["name"] for c in cookies if c["value"] and c["path"] == "/" and c["domain"].lstrip(".") in ("youtube.com", "music.youtube.com")}
    return "LOGIN_INFO" in names and bool(names & {"SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"})


def read_snapshot(source):
    permit(source)
    _, ticket = source_parts(source)
    path = root() / f"{ticket}.session"
    try:
        if path.stat().st_size > MAX_BYTES + 8192:
            raise ValueError()
        snapshot = json.loads(protect(path.read_bytes(), decrypt=True))
        cookies = normalized_cookies(snapshot["cookies"])
    except (OSError, ValueError, KeyError, TypeError):
        raise RuntimeError("Open the Resonance connector in your browser and press Connect.") from None
    if not signed_in(cookies):
        raise RuntimeError("Sign in to YouTube in this browser, then reconnect Resonance.")
    return cookies


def load_cookie_jar(source):
    with locked():
        cookies = read_snapshot(source)
    jar = http.cookiejar.MozillaCookieJar()
    for item in cookies:
        domain = item["domain"]
        jar.set_cookie(http.cookiejar.Cookie(0, item["name"], item["value"], None, False, domain, domain.startswith("."), domain.startswith("."), item["path"], True, item["secure"], item["expirationDate"], item["expirationDate"] is None, None, None, {"HttpOnly": None} if item["httpOnly"] else {}))
    return jar


def native_request(message):
    if not isinstance(message, dict):
        raise RuntimeError("Invalid connector request.")
    with locked():
        if message.get("command") == "pending":
            candidates = []
            for path in root().glob("*.permit.json"):
                try:
                    info = json.loads(path.read_text(encoding="utf-8"))
                    if info.get("state") == "pending" and 0 <= time.time() - info.get("created", 0) < 600:
                        candidates.append(info)
                except (OSError, ValueError):
                    pass
            if not candidates:
                raise RuntimeError("Press Connect browser session in Resonance first.")
            selected = max(candidates, key=lambda entry: entry["created"])
            return {"ok": True, "source": selected["source"], "browser": selected["browser"]}
        if message.get("command") != "export":
            raise RuntimeError("Unsupported connector request.")
        source = message.get("source")
        permit(source)
        _, ticket = source_parts(source)
        cookies = normalized_cookies(message.get("cookies"))
        path = root() / f"{ticket}.session"
        if not signed_in(cookies):
            path.unlink(missing_ok=True)
            raise RuntimeError("Sign in to YouTube in this browser, then press Connect.")
        snapshot = json.dumps({"cookies": cookies, "updated": time.time()}).encode("utf-8")
        atomic_write(path, protect(snapshot))
        return {"ok": True}


def serve(origin, input_stream=None, output_stream=None):
    if origin != ORIGIN:
        return 1
    # Windows CRT text mode corrupts binary native-messaging length prefixes.
    if input_stream is None:
        import msvcrt
        msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
        msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
    incoming, outgoing = input_stream or sys.stdin.buffer, output_stream or sys.stdout.buffer
    try:
        header = incoming.read(4)
        if len(header) != 4:
            return 1
        size = struct.unpack("<I", header)[0]
        if size == 0 or size > MAX_BYTES:
            return 1
        payload = incoming.read(size)
        if len(payload) != size:
            return 1
        result = native_request(json.loads(payload))
    except Exception:
        # Never include exception values/payloads/cookies in logs or responses.
        result = {"ok": False, "error": "Connect from Resonance first, and make sure YouTube is signed in."}
    encoded = json.dumps(result).encode("utf-8")
    outgoing.write(struct.pack("<I", len(encoded)) + encoded)
    outgoing.flush()
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith("chrome-extension://"):
        raise SystemExit(serve(sys.argv[1]))
    parser = argparse.ArgumentParser()
    parser.add_argument("--connector-tool", choices=("activate", "revoke", "export"), required=True)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()
    try:
        _, ticket = source_parts(args.source)
        if args.connector_tool == "export":
            jar = load_cookie_jar(args.source)
            leases = root() / "leases"
            leases.mkdir(exist_ok=True)
            for old in leases.glob("*.txt"):
                if time.time() - old.stat().st_mtime > 86400:
                    try:
                        old.unlink()
                    except OSError:
                        pass
            handle, name = tempfile.mkstemp(suffix=".txt", dir=leases)
            os.close(handle)
            try:
                jar.save(name, ignore_discard=True, ignore_expires=False)
            except Exception:
                Path(name).unlink(missing_ok=True)
                raise
            result = {"path": name}
        else:
            with locked():
                if args.connector_tool == "activate":
                    info = permit(args.source)
                    read_snapshot(args.source)
                    info["state"] = "active"
                    atomic_write(root() / f"{ticket}.permit.json", json.dumps(info).encode("utf-8"))
                else:
                    for suffix in (".permit.json", ".session"):
                        (root() / f"{ticket}{suffix}").unlink(missing_ok=True)
            result = {"ok": True}
        print(json.dumps(result))
    except Exception:
        print("Reconnect the Resonance browser connector after signing in to YouTube.", file=sys.stderr)
        raise SystemExit(1)
