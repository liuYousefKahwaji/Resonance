"""Reuse verified runs and recover a fully uploaded draft without rebuilding."""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import release as r


def verified_run(run_id):
    run = r.api(f'/actions/runs/{run_id}')
    if (not run or run.get('path') != '.github/workflows/release.yml' or run.get('head_branch') != 'main' or
            (run.get('head_repository') or {}).get('full_name') != r.REPO or
            run.get('event') not in ('push', 'workflow_dispatch') or run.get('status') != 'completed' or
            run.get('conclusion') not in ('success', 'failure')):
        raise ValueError('Expected a completed release workflow from this repository main branch')
    jobs = r.api(f'/actions/runs/{run_id}/jobs?per_page=100')
    states = {job['name']: job['conclusion'] for job in jobs['jobs']}
    built = all(states.get(name) == 'success' for name in ('windows', 'android', 'prepare'))
    if states.get('detect') != 'success' or not (built or states.get('reuse') == 'success'):
        raise ValueError('Source run did not finish all build/verification stages')
    return run


def reusable_run(semver, source_sha, current_run=''):
    source_tree = r.commit_tree(source_sha)
    runs = r.api('/actions/workflows/release.yml/runs?branch=main&per_page=30') or {}
    for run in runs.get('workflow_runs', []):
        if str(run['id']) == str(current_run) or run.get('status') != 'completed': continue
        if run.get('conclusion') not in ('success', 'failure'): continue
        if (run.get('head_commit') or {}).get('tree_id') != source_tree: continue
        try: trusted = verified_run(run['id'])
        except ValueError: continue
        artifacts = r.api(f"/actions/runs/{run['id']}/artifacts?per_page=100") or {}
        matches = [a for a in artifacts.get('artifacts', [])
                   if a['name'] == f'verified-release-{semver}' and not a['expired']]
        if len(matches) == 1: return trusted
    return None


def reuse(args):
    source_sha = os.environ['GITHUB_SHA']
    found = None if args.force else reusable_run(args.version, source_sha, os.getenv('GITHUB_RUN_ID', ''))
    values = dict(reuse_run=str(found['id']) if found else '', source_sha=found['head_sha'] if found else source_sha)
    print(json.dumps(values))
    if os.getenv('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.writelines(f'{key}={value}\n' for key, value in values.items())


def small_asset(entry):
    if entry.get('size', 0) <= 0 or entry['size'] > 1024 * 1024: raise ValueError('Oversized release metadata')
    # gh handles authenticated redirects without leaking credentials in output.
    data = subprocess.run(['gh', 'api', f"repos/{r.REPO}/releases/assets/{entry['id']}",
        '--header', 'Accept: application/octet-stream'], capture_output=True, check=True).stdout
    if len(data) != entry['size'] or entry.get('digest') != 'sha256:' + hashlib.sha256(data).hexdigest():
        raise ValueError('Downloaded release metadata identity mismatch')
    return data


def recover(args):
    run = verified_run(args.run_id)
    semver, build = r.pubspec()
    remote = r.find_release('v' + semver)
    if not remote: raise ValueError('No release draft found')
    r.check_draft_source(remote, run['head_sha'])
    names = {a['name']: a for a in remote['assets']}
    data = small_asset(names[f'resonance-v{semver}-update.json'])
    signature = small_asset(names[f'resonance-v{semver}-update.sig'])
    manifest, expected = r.publication_metadata(data, signature)
    r.checked_remote_assets(remote, expected)
    for path, wanted in [(f'release/v{semver}/patchnotes.md', manifest['release']['notes']), ('pubspec.yaml', None)]:
        content = r.api(f"/contents/{path}?ref={run['head_sha']}")
        if not content or content.get('encoding') != 'base64': raise ValueError('Source release metadata unavailable')
        text = base64.b64decode(content['content']).decode().replace('\r\n', '\n')
        if wanted is not None and text != wanted: raise ValueError('Signed notes differ from verified source run')
        if wanted is None and f'version: {semver}+{build}' not in text.splitlines():
            raise ValueError('Verified run version differs from release')
    print(f"Verified all {len(expected)} uploaded assets, signature, version, notes, and source run {args.run_id}.")
    if args.publish:
        r.finish_publication(remote, manifest, expected)
    else:
        print('Read-only check complete. Add --publish to publish the verified draft; no rebuilding or uploading required.')


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('reuse')
    command.add_argument('--version', required=True)
    command.add_argument('--force', action='store_true')
    command = commands.add_parser('recover-draft')
    command.add_argument('--run-id', type=int, required=True)
    command.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    {'reuse': reuse, 'recover-draft': recover}[args.command](args)


if __name__ == '__main__': main()
