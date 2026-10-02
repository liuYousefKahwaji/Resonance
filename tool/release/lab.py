"""Local-only signed update feed with range requests and controlled failures.

Never calls GitHub. The production app does not accept this feed or its key.
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import shutil
import time
import urllib.parse
import release as r


def configure(root, seed, mode, port):
    manifests = list(root.glob('resonance-v*-update.json'))
    if len(manifests) != 1: raise ValueError('Lab feed must contain exactly one target release')
    manifest_path = manifests[0]
    original = root / '.original-manifest'
    if not original.exists(): shutil.copyfile(manifest_path, original)
    manifest = json.loads(original.read_bytes())
    platforms = [platform for platform in ['android', 'windows'] if platform in manifest]
    if not platforms: raise ValueError('Lab feed has no platforms')
    if mode == 'full':
        for platform in platforms: manifest[platform]['deltaEnabled'] = False
    if mode == 'wrong-source':
        for platform, field in [('android', 'sourceApkSha256'), ('windows', 'sourceTreeSha256')]:
            if platform not in platforms: continue
            for delta in manifest[platform]['deltas']: delta[field] = '0'*64
    if mode == 'corrupt-patch':
        for platform in platforms:
            for delta in manifest[platform]['deltas']:
                name = 'corrupt-' + delta['name']
                file = root / name; file.write_bytes(b'not a patch\n')
                delta.update(r.asset(file))
    r.write_json(manifest_path, manifest)
    r.sign_manifest(manifest_path, base64.b64encode(seed.read_bytes()).decode(), 'resonance-test')
    if mode == 'bad-signature': manifest_path.write_bytes(manifest_path.read_bytes() + b' ')
    names = {manifest_path.name, manifest_path.with_suffix('.sig').name}
    if 'windows' in platforms: names.add(manifest['windows']['fileManifest']['name'])
    for platform in platforms:
        names.add(manifest[platform]['full']['name'])
        names.update(d['name'] for d in manifest[platform]['deltas'])
    assets = [dict(name=name, size=(root/name).stat().st_size, digest='sha256:'+r.sha(root/name),
                   browser_download_url=f'http://127.0.0.1:{port}/{urllib.parse.quote(name)}') for name in sorted(names)]
    r.write_json(root / 'release.json', dict(tag_name=manifest['release']['tag'], body=manifest['release']['notes'],
        draft=False, prerelease=False, assets=assets))
    return names | {'release.json'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path('build/update-lab/feed'))
    parser.add_argument('--seed', type=Path, default=Path('build/update-lab/test-manifest.seed'))
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--chunk-delay', type=float, default=0, help='Local test transfer delay per 64 KiB, in seconds')
    parser.add_argument('--mode', choices=['normal', 'full', 'corrupt-patch', 'bad-signature', 'wrong-source', 'interrupted-download'], default='normal')
    args = parser.parse_args(); root = args.root.resolve()
    if not 0 <= args.chunk_delay <= 1: parser.error('chunk-delay must be between 0 and 1 second')
    allowed = configure(root, args.seed, args.mode, args.port)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def do_HEAD(self): self.send_file(head=True)
        def do_GET(self): self.send_file(head=False)
        def send_file(self, head):
            name = urllib.parse.unquote(urllib.parse.urlparse(self.path).path).removeprefix('/')
            if name not in allowed: self.send_error(404); return
            path = root / name; size = path.stat().st_size
            start, end = 0, size-1; partial = False
            raw_range = self.headers.get('Range')
            if raw_range:
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', raw_range)
                if not match: self.send_error(416); return
                start = int(match[1]); end = min(size-1, int(match[2]) if match[2] else size-1)
                if start > end: self.send_error(416); return
                partial = True
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(end-start+1)); self.send_header('Accept-Ranges', 'bytes')
            if partial: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            if head: return
            try:
                with path.open('rb') as file:
                    file.seek(start); remaining = end-start+1
                    while remaining:
                        data = file.read(min(65536, remaining)); self.wfile.write(data); remaining -= len(data)
                        if not name.endswith(('.json', '.sig')):
                            delay = args.chunk_delay or (.01 if args.mode == 'interrupted-download' else 0)
                            if delay: time.sleep(delay)  # Allows cancellation/server termination and resume testing.
            except (BrokenPipeError, ConnectionResetError): pass
    print(f'Local update lab: http://127.0.0.1:{args.port}/release.json ({args.mode})', flush=True)
    print('No GitHub changes. Stop with Ctrl+C. Android: adb reverse tcp:8765 tcp:8765', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__': main()
