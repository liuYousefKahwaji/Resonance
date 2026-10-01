"""Canonical build metadata, verified direct deltas, and signed release assets.

No command publishes unless --publish is explicitly supplied. Local fixtures
and workflow_dispatch dry runs do not create tags, releases, or announcements.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import urllib.request
import urllib.error
from zipfile import ZipFile, ZIP_DEFLATED

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

REPO = 'liuYousefKahwaji/Resonance'
CERT = 'd504a82e662a5a2596607084b2b64d84170519c3193fc7d7cc915bdfdc794fba'
XDELTA_COMMIT = '2c36417e6d09bf700d3d1cca44ed3e42101016c3'
ROOT = Path(__file__).resolve().parents[2]
HEX = re.compile(r'^[0-9a-f]{64}$')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    Path(path).write_bytes((json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode())


def version(text):
    match = re.fullmatch(r'[vV]\.?(\d+)\.(\d+)\.(\d+)', text.strip()) or re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', text.strip())
    if not match:
        raise ValueError(f'Invalid stable version: {text}')
    return tuple(map(int, match.groups()))


def pubspec():
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', (ROOT / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise ValueError('pubspec requires a semantic version and positive build number')
    return match[1], int(match[2])


def safe_path(name):
    if not isinstance(name, str) or not name or '\\' in name or ':' in name or '\x00' in name:
        raise ValueError('Invalid managed path')
    path = PurePosixPath(name)
    if path.is_absolute() or str(path) != name or any(p in ('', '.', '..') or p.endswith((' ', '.')) for p in path.parts):
        raise ValueError('Unsafe managed path')
    if any(re.fullmatch(r'(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\..*)?', p) for p in path.parts):
        raise ValueError('Reserved Windows path')
    return name


def tree_hash(files):
    return hashlib.sha256(''.join(f"{f['path']}\0{f['size']}\0{f['sha256']}\n" for f in files).encode()).hexdigest()


def path_order(name):
    # Dart String.compareTo and .NET CompareOrdinal compare UTF-16 code units.
    return name.encode('utf-16-be')


def file_manifest(root, semver):
    files, seen = [], set()
    for file in sorted(Path(root).rglob('*'), key=lambda p: path_order(p.relative_to(root).as_posix())):
        if file.is_symlink():
            raise ValueError('Symlinks are not release files')
        if not file.is_file() or file.name == 'resonance-install.json':
            continue
        name = safe_path(file.relative_to(root).as_posix())
        if name.lower() in seen:
            raise ValueError('Case-colliding release paths')
        seen.add(name.lower())
        files.append(dict(path=name, size=file.stat().st_size, sha256=sha(file)))
    return dict(schemaVersion=1, version=semver, files=files, treeSha256=tree_hash(files))


def validate_files(manifest):
    if manifest.get('schemaVersion') != 1 or not isinstance(manifest.get('files'), list):
        raise ValueError('Unsupported file manifest')
    seen = set()
    for f in manifest['files']:
        name = safe_path(f['path'])
        if name.lower() in seen or not isinstance(f['size'], int) or f['size'] < 0 or not HEX.fullmatch(f['sha256']):
            raise ValueError('Invalid file entry')
        seen.add(name.lower())
    if manifest['files'] != sorted(manifest['files'], key=lambda f: path_order(f['path'])) or tree_hash(manifest['files']) != manifest['treeSha256']:
        raise ValueError('Invalid tree digest')


def verify_tree(root, manifest):
    validate_files(manifest)
    for f in manifest['files']:
        path = Path(root) / f['path']
        if path.is_symlink() or not path.resolve().is_relative_to(Path(root).resolve()) or not path.is_file() or path.stat().st_size != f['size'] or sha(path) != f['sha256']:
            raise ValueError(f"Tree mismatch: {f['path']}")


def extract(zip_path, root):
    seen = set()
    with ZipFile(zip_path) as archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            name = safe_path(info.filename)
            if name.lower() in seen or info.external_attr >> 16 & 0o170000 == 0o120000:
                raise ValueError('Unsafe ZIP entry')
            seen.add(name.lower())
            if info.file_size > 2 * 1024**3:
                raise ValueError('Oversized entry')
        if sum(i.file_size for i in archive.infolist()) > 4 * 1024**3:
            raise ValueError('Oversized archive')
        archive.extractall(root)


def zip_tree(root, destination):
    with ZipFile(destination, 'w', ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(Path(root).rglob('*')):
            if file.is_file():
                archive.write(file, safe_path(file.relative_to(root).as_posix()))


def windows_delta(old_zip, new_root, semver, output):
    target = file_manifest(new_root, semver)
    with tempfile.TemporaryDirectory() as tmp:
        old_root, payload = Path(tmp) / 'old', Path(tmp) / 'delta'
        old_root.mkdir(); payload.mkdir()
        extract(old_zip, old_root)
        installed = old_root / 'resonance-install.json'
        if not installed.is_file():
            return None  # Old updater cannot consume patches; bootstrap full.
        source = json.loads(installed.read_text(encoding='utf-8'))
        verify_tree(old_root, source)
        old_files = {f['path']: f for f in source['files']}
        new_files = {f['path']: f for f in target['files']}
        changed = [f for f in target['files'] if old_files.get(f['path']) != f]
        deleted = sorted(set(old_files) - set(new_files))
        metadata = dict(schemaVersion=1, source=source, target=target, changed=changed, deleted=deleted)
        write_json(payload / 'delta.json', metadata)
        for f in changed:
            dest = payload / 'payload' / f['path']; dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(Path(new_root) / f['path'], dest)
            (old_root / f['path']).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(dest, old_root / f['path'])
        for name in deleted:
            (old_root / name).unlink()
        verify_tree(old_root, target)
        zip_tree(payload, output)
    return dict(fromVersion=source['version'], sourceTreeSha256=source['treeSha256'], targetTreeSha256=target['treeSha256'])


def asset(path):
    path = Path(path)
    return dict(name=path.name, size=path.stat().st_size, sha256=sha(path))


def sign_manifest(path, seed, key_id):
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(seed, validate=True))
    sig = dict(keyId=key_id, signature=base64.b64encode(key.sign(Path(path).read_bytes())).decode())
    write_json(Path(path).with_suffix('.sig'), sig)


def verify_signature(data, sig, keys):
    value = json.loads(sig)
    public = base64.b64decode(keys[value['keyId']], validate=True)
    Ed25519PublicKey.from_public_bytes(public).verify(base64.b64decode(value['signature'], validate=True), data)


def keys():
    return json.loads((ROOT / 'assets/update/trusted_keys.json').read_text())['keys']


def keygen(args):
    if args.private.exists() or args.public.exists():
        raise ValueError('Refusing to overwrite a signing identity')
    key = Ed25519PrivateKey.generate()
    args.private.parent.mkdir(parents=True, exist_ok=True)
    args.private.write_bytes(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))
    args.public.parent.mkdir(parents=True, exist_ok=True)
    write_json(args.public, dict(schemaVersion=1, keys={args.key_id: base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()}))
    print(f'Created public trust file {args.public}. Private seed is only at {args.private}. Back it up securely.')


def api(path):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'Resonance-Release'}
    if os.getenv('GH_TOKEN'):
        headers['Authorization'] = f"Bearer {os.environ['GH_TOKEN']}"
    try:
        with urllib.request.urlopen(urllib.request.Request('https://api.github.com/repos/' + REPO + path, headers=headers), timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def fetch_asset(entry, directory):
    url = entry['browser_download_url']
    if not url.startswith(f'https://github.com/{REPO}/releases/download/'):
        raise ValueError('Unexpected release URL')
    path = Path(directory) / safe_path(entry['name'])
    if '/' in entry['name'] or not entry.get('digest', '').startswith('sha256:'):
        raise ValueError('Missing canonical asset digest')
    with urllib.request.urlopen(url, timeout=60) as response, path.open('wb') as output:
        shutil.copyfileobj(response, output)
    if path.stat().st_size != entry['size'] or sha(path) != entry['digest'][7:]:
        raise ValueError('Previous asset failed verification')
    return path


def detect(args):
    current, build = pubspec()
    latest = api('/releases/latest')
    published = version(latest['tag_name']) if latest else (0, 0, 0)
    if version(current) < published:
        raise ValueError('Version regressed below the latest release')
    should_build = args.force_build or version(current) > published
    if version(current) > published and latest:
        # Signed manifests carry the canonical build number. Pre-bootstrap
        # releases use the audited 3.4.4+11 migration baseline.
        manifests = [a for a in latest['assets'] if a['name'].endswith('-update.json')]
        if manifests:
            sigs = [a for a in latest['assets'] if a['name'].endswith('-update.sig')]
            if len(manifests) != 1 or len(sigs) != 1:
                raise ValueError('Ambiguous signed release metadata')
            with tempfile.TemporaryDirectory() as tmp:
                data = fetch_asset(manifests[0], tmp).read_bytes()
                sig = fetch_asset(sigs[0], tmp).read_bytes()
                verify_signature(data, sig, keys())
                signed = json.loads(data)['release']
                if version(signed['version']) != published or version(signed['tag']) != published:
                    raise ValueError('Signed latest release identity mismatch')
                previous_build = signed['buildNumber']
        else:
            if published > (3, 4, 4):
                raise ValueError('Post-bootstrap release lacks signed metadata')
            previous_build = 11
        if build <= previous_build:
            raise ValueError('Android build number must increase')
    notes = ROOT / f'release/v{current}/patchnotes.md'
    if should_build and (not notes.is_file() or not notes.read_text(encoding='utf-8').strip()):
        raise ValueError(f'Missing committed patch notes: {notes}')
    if should_build and not args.dry_run:
        tag = subprocess.run(['git', 'ls-remote', '--tags', 'origin', f'refs/tags/v{current}'], check=True, capture_output=True, text=True).stdout.strip()
        if tag or api(f'/releases/tags/v{current}'):
            raise ValueError('Version tag/release already exists; use explicit recovery, never overwrite')
    values = dict(version=current, build=str(build), release=str(should_build).lower(), publish=str(not args.dry_run and version(current) > published).lower())
    print(json.dumps(values))
    if os.getenv('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.writelines(f'{k}={v}\n' for k, v in values.items())


def package_windows(args):
    semver, _ = pubspec()
    if args.version: semver = args.version.split('+')[0]
    output = args.output; output.mkdir(parents=True, exist_ok=True)
    notices = args.root / 'LICENSES'; notices.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'third_party/xdelta/LICENSE', notices / 'xdelta.txt')
    (args.root / 'Recover Resonance.cmd').write_text('@echo off\ncd /d "%~dp0"\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "data\\flutter_assets\\assets\\windows\\recover_update.ps1"\n', encoding='utf-8')
    manifest = file_manifest(args.root, semver)
    required = {'resonance.exe', 'flutter_windows.dll', 'data/app.so', 'data/flutter_assets/assets/windows/apply_update.ps1', 'data/flutter_assets/assets/windows/apply_update_transaction.ps1'}
    if not required <= {f['path'] for f in manifest['files']}:
        raise ValueError('Incomplete Windows runtime')
    write_json(args.root / 'resonance-install.json', manifest)
    write_json(output / f'resonance-v{semver}-windows.files.json', manifest)
    zip_tree(args.root, output / f'resonance-v{semver}-windows.zip')


def prepare(args):
    semver, build = pubspec()
    if args.version:
        semver, build = args.version.split('+'); build = int(build)
    verify_apk(args.apk, semver, build, args.package)
    output = args.output; output.mkdir(parents=True, exist_ok=True)
    apk = output / f'resonance-v{semver}.apk'
    if args.apk.resolve() != apk.resolve(): shutil.copyfile(args.apk, apk)
    full_zip = output / f'resonance-v{semver}-windows.zip'
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'target'; root.mkdir()
        extract(args.windows, root)
        target = file_manifest(root, semver)
        write_json(root / 'resonance-install.json', target)
        zip_tree(root, full_zip)
        files = output / f'resonance-v{semver}-windows.files.json'; write_json(files, target)
        android = dict(full={**asset(apk), 'signingCertSha256': CERT, 'packageName': args.package, 'versionCode': build}, deltas=[])
        windows = dict(full=asset(full_zip), fileManifest=asset(files), deltas=[])
        bases = []
        if args.bases:
            bases = json.loads(args.bases.read_text())
        elif args.previous:
            with tempfile.TemporaryDirectory() as previous:
                releases = api('/releases?per_page=30') or []
                for release in releases:
                    if release['draft'] or release['prerelease']: continue
                    try: old_version = version(release['tag_name'])
                    except ValueError: continue
                    if not (3, 4, 5) <= old_version < version(semver): continue
                    from datetime import datetime, timezone, timedelta
                    if datetime.fromisoformat(release['published_at'].replace('Z', '+00:00')) < datetime.now(timezone.utc) - timedelta(days=90): continue
                    old_apk = next((a for a in release['assets'] if re.fullmatch(r'resonance-v[0-9.]+\.apk', a['name'])), None)
                    old_zip = next((a for a in release['assets'] if re.fullmatch(r'resonance-v[0-9.]+-windows\.zip', a['name'])), None)
                    if not old_apk or not old_zip: continue
                    bases.append(dict(version='.'.join(map(str, old_version)), apk=str(fetch_asset(old_apk, previous)), windows=str(fetch_asset(old_zip, previous))))
                    if len(bases) >= 5: break
                _deltas(args, semver, apk, root, full_zip, bases, android, windows)
                bases = []
        _deltas(args, semver, apk, root, full_zip, bases, android, windows)
        manifest = dict(schemaVersion=1, release=dict(version=semver, buildNumber=build, tag=f'v{semver}', notes=args.notes.read_text(encoding='utf-8')), android=android, windows=windows)
        path = output / f'resonance-v{semver}-update.json'; write_json(path, manifest)
        seed = os.getenv('UPDATE_MANIFEST_SIGNING_KEY_B64')
        if args.seed: seed = base64.b64encode(args.seed.read_bytes()).decode()
        if not seed: raise ValueError('Missing manifest signing key')
        sign_manifest(path, seed, args.key_id)
        trust = json.loads(args.trust.read_text())['keys'] if args.trust else keys()
        verify_signature(path.read_bytes(), path.with_suffix('.sig').read_bytes(), trust)
        verify_tree(root, target)
        for section in (windows, android):
            for entry in [section['full'], *section['deltas']]:
                if sha(output / entry['name']) != entry['sha256']: raise ValueError('Asset changed after signing')
        print(json.dumps(dict(version=semver, windows=windows, android=android), indent=2))


def verify_apk(path, semver, build, package):
    sdk = os.getenv('ANDROID_SDK_ROOT') or os.getenv('ANDROID_HOME')
    if not sdk and os.name == 'nt': sdk = str(Path(os.environ['LOCALAPPDATA']) / 'Android/Sdk')
    if not sdk: raise ValueError('Android SDK required to validate canonical APK')
    candidates = [p for p in (Path(sdk) / 'build-tools').iterdir() if p.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+', p.name)]
    tools = max(candidates, key=lambda p: tuple(map(int, p.name.split('.'))))
    signer = tools / ('apksigner.bat' if os.name == 'nt' else 'apksigner')
    cert = subprocess.run([str(signer), 'verify', '--print-certs', str(path)], capture_output=True, text=True, check=True).stdout
    digests = re.findall(r'^(?:Signer #\d+|V[1-4] Signer:) certificate SHA-256 digest: ([a-f0-9]+)$', cert, re.M)
    if set(digests) != {CERT}: raise ValueError('APK does not use the established signing certificate')
    aapt = tools / ('aapt.exe' if os.name == 'nt' else 'aapt')
    badging = subprocess.run([str(aapt), 'dump', 'badging', str(path)], capture_output=True, text=True, check=True).stdout
    match = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    if not match or match[1] != package or (build is not None and int(match[2]) != build) or match[3] != semver:
        raise ValueError('Canonical APK package/version differs from release metadata')


def _deltas(args, semver, apk, root, full_zip, bases, android, windows):
    for base in bases:
        if version(base['version']) >= version(semver): raise ValueError('Invalid delta base')
        prefix = f"resonance-v{base['version']}-to-v{semver}"
        win = args.output / (prefix + '-windows.delta.zip')
        metadata = windows_delta(base['windows'], root, semver, win)
        if metadata and win.stat().st_size < full_zip.stat().st_size * .7:
            windows['deltas'].append({**asset(win), **metadata})
        elif win.exists(): win.unlink()
        old_apk = Path(base['apk'])
        verify_apk(old_apk, base['version'], None, args.package)
        patch = args.output / (prefix + '-android.xdelta')
        rebuilt = args.output / (prefix + '.rebuilt.apk')
        subprocess.run([str(args.xdelta), '-e', '-f', '-S', 'none', '-B', '16777216', '-W', '8388608', '-s', str(old_apk), str(apk), str(patch)], check=True)
        subprocess.run([str(args.decoder), str(old_apk), str(patch), str(rebuilt), str(apk.stat().st_size)], check=True)
        if sha(rebuilt) != sha(apk): raise ValueError('Patch failed canonical reconstruction')
        rebuilt.unlink()
        if patch.stat().st_size < apk.stat().st_size * .7:
            android['deltas'].append({**asset(patch), 'fromVersion': base['version'], 'sourceApkSha256': sha(old_apk), 'targetApkSha256': sha(apk), 'algorithm': 'xdelta3-vcdiff'})
        else: patch.unlink()


def publish(args):
    if not args.publish: raise ValueError('Publication requires explicit --publish')
    semver, _ = pubspec(); tag = f'v{semver}'
    if api(f'/releases/tags/{tag}'): raise ValueError('Release already exists')
    # Keep incomplete assets invisible to clients. Full assets are uploaded
    # first so pre-bootstrap clients always choose the correct full package.
    manifest_path = args.output / f'resonance-v{semver}-update.json'
    verify_signature(manifest_path.read_bytes(), manifest_path.with_suffix('.sig').read_bytes(), keys())
    manifest = json.loads(manifest_path.read_bytes())
    if manifest['release']['version'] != semver: raise ValueError('Publication version mismatch')
    metadata = [manifest['android']['full'], manifest['windows']['full'], manifest['windows']['fileManifest'],
                *manifest['android']['deltas'], *manifest['windows']['deltas']]
    names = {m['name'] for m in metadata} | {manifest_path.name, manifest_path.with_suffix('.sig').name}
    if {p.name for p in args.output.iterdir()} != names: raise ValueError('Publication directory contains unexpected files')
    for entry in metadata:
        path = args.output / safe_path(entry['name'])
        if path.stat().st_size != entry['size'] or sha(path) != entry['sha256']: raise ValueError('Publication asset identity mismatch')
    assets = sorted(args.output.iterdir(), key=lambda p: ('.delta.' in p.name or p.suffix == '.xdelta', p.name))
    subprocess.run(['gh', 'release', 'create', tag, '--draft', '--target', os.environ['GITHUB_SHA'], '--title', tag, '--notes-file', str(ROOT / f'release/{tag}/patchnotes.md')], check=True)
    for path in assets:
        subprocess.run(['gh', 'release', 'upload', tag, str(path)], check=True)
    remote = api(f'/releases/tags/{tag}')
    by_name = {a['name']: a for a in remote['assets']}
    for path in assets:
        if by_name[path.name].get('digest') != 'sha256:' + sha(path): raise ValueError('Uploaded asset digest mismatch; release remains draft')
    subprocess.run(['gh', 'release', 'edit', tag, '--draft=false', '--latest'], check=True)


def main():
    parser = argparse.ArgumentParser(); commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('keygen'); p.add_argument('--private', type=Path, required=True); p.add_argument('--public', type=Path, required=True); p.add_argument('--key-id', default='resonance-2026-01')
    p = commands.add_parser('detect'); p.add_argument('--dry-run', action='store_true'); p.add_argument('--force-build', action='store_true')
    p = commands.add_parser('windows'); p.add_argument('--root', type=Path, required=True); p.add_argument('--output', type=Path, required=True); p.add_argument('--version')
    p = commands.add_parser('prepare'); p.add_argument('--windows', type=Path, required=True); p.add_argument('--apk', type=Path, required=True); p.add_argument('--output', type=Path, required=True); p.add_argument('--xdelta', type=Path, required=True); p.add_argument('--decoder', type=Path, required=True); p.add_argument('--notes', type=Path, required=True); p.add_argument('--bases', type=Path); p.add_argument('--previous', action='store_true'); p.add_argument('--seed', type=Path); p.add_argument('--trust', type=Path); p.add_argument('--version'); p.add_argument('--package', default='com.example.resonance'); p.add_argument('--key-id', default='resonance-2026-01')
    p = commands.add_parser('publish'); p.add_argument('--output', type=Path, required=True); p.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    dict(keygen=keygen, detect=detect, windows=package_windows, prepare=prepare, publish=publish)[args.command](args)


if __name__ == '__main__':
    main()
