"""Explicit setup helper. Does nothing remotely without --configure-github."""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import release as r
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--configure-github', action='store_true')
    parser.add_argument('--seed', type=Path, default=Path.home()/'.resonance-release-secrets/update-manifest.seed')
    parser.add_argument('--keystore', type=Path, default=Path.home()/'.android/debug.keystore')
    args = parser.parse_args()
    seed = args.seed.read_bytes()
    public = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    if base64.b64encode(public).decode() != r.keys()['resonance-2026-01']: raise ValueError('Manifest seed differs from embedded public key')
    cert = subprocess.run(['keytool', '-list', '-keystore', str(args.keystore), '-storepass', 'android', '-alias', 'androiddebugkey'],
        capture_output=True, text=True, check=True).stdout
    if r.CERT not in cert.lower().replace(':', ''): raise ValueError('Keystore differs from existing Android signing identity')
    print('Local signing identities verified. Private values are not displayed.')
    if not args.configure_github:
        print('No GitHub changes. Add --configure-github to set the five signing secrets explicitly.')
        return
    values = {'ANDROID_KEYSTORE_B64': base64.b64encode(args.keystore.read_bytes()).decode(),
        'ANDROID_KEYSTORE_PASSWORD': 'android', 'ANDROID_KEY_ALIAS': 'androiddebugkey', 'ANDROID_KEY_PASSWORD': 'android',
        'UPDATE_MANIFEST_SIGNING_KEY_B64': base64.b64encode(seed).decode()}
    for name, value in values.items():
        subprocess.run(['gh', 'secret', 'set', name, '--repo', r.REPO], input=value, text=True, check=True)
    print('Signing secrets configured. Automatic publishing remains disabled until the repository variable is enabled.')


if __name__ == '__main__': main()
