"""Called explicitly after Actions publication, or by the manual release listener."""
import json
import os
import urllib.request
from pathlib import Path
import release


def main():
    webhook = os.getenv('DISCORD_WEBHOOK_URL')
    if not webhook:
        print('No Discord webhook configured; announcement skipped')
        return
    if os.getenv('GITHUB_EVENT_NAME') == 'release':
        published = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())['release']
    else:
        semver, _ = release.pubspec()
        published = release.api('/releases/tags/v' + semver)
    if not published or published['draft'] or published['prerelease']:
        raise ValueError('Only a published stable release may be announced')
    role = os.getenv('ROLE_ID', '')
    prefix = f'<@&{role}>\n\n' if role.isdigit() else ''
    text = prefix + f"## 🎵 {published['name'] or published['tag_name']}\n{published['html_url']}\n\n{published.get('body', '')}"
    first = True
    while text:
        boundary = min(len(text), 1900)
        if len(text) > boundary:
            split = text.rfind('\n', 0, boundary)
            if split > boundary // 2: boundary = split
        chunk, text = text[:boundary], text[boundary:].lstrip()
        payload = {'content': chunk, 'allowed_mentions': {'roles': [role] if first and role.isdigit() else [], 'users': [], 'parse': []}}
        request = urllib.request.Request(webhook, data=json.dumps(payload).encode(), method='POST', headers={'Content-Type': 'application/json', 'User-Agent': 'Resonance-Release'})
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status not in (200, 204): raise RuntimeError('Discord announcement failed')
        first = False


if __name__ == '__main__':
    main()
