"""Benchmark real APK pairs; never invent savings from source-code size."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--xdelta', required=True)
    parser.add_argument('--decoder', required=True)
    parser.add_argument('--zstd', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('apks', nargs='+', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for old, new in zip(args.apks, args.apks[1:]):
        patch = args.output / f'{old.stem}-to-{new.stem}.xdelta'
        rebuilt = patch.with_suffix('.rebuilt.apk')
        started = time.monotonic()
        subprocess.run([args.xdelta, '-e', '-f', '-S', 'none', '-B', '16777216', '-W', '8388608',
                        '-s', str(old), str(new), str(patch)], check=True)
        encoded = time.monotonic() - started
        started = time.monotonic()
        subprocess.run([args.decoder, str(old), str(patch), str(rebuilt), str(new.stat().st_size)], check=True)
        decoded = time.monotonic() - started
        assert digest(rebuilt) == digest(new), 'Reconstruction differs from canonical signed APK'
        results.append(dict(source=old.name, target=new.name, algorithm='xdelta3-vcdiff',
                            fullBytes=new.stat().st_size, patchBytes=patch.stat().st_size,
                            encodeSeconds=round(encoded, 3), decodeSeconds=round(decoded, 3)))
        # These are host benchmarks. Android peak RSS and latency must also be
        # measured with the shipped streaming decoder on a device/emulator.
        import bsdiff4
        source, target = old.read_bytes(), new.read_bytes()
        for algorithm in ['zstd-patch-from-19', 'bsdiff']:
            started = time.monotonic()
            if algorithm == 'zstd-patch-from-19':
                zpatch = patch.with_suffix('.zst')
                subprocess.run([args.zstd, '-19', '--patch-from='+str(old), str(new), '-o', str(zpatch), '-f'], check=True)
                data = zpatch.read_bytes()
                encoded = time.monotonic() - started
                started = time.monotonic()
                subprocess.run([args.zstd, '-d', '--patch-from='+str(old), str(zpatch), '-o', str(rebuilt), '-f'], check=True)
                output = rebuilt.read_bytes()
            else:
                data = bsdiff4.diff(source, target)
                encoded = time.monotonic() - started
                started = time.monotonic()
                output = bsdiff4.patch(source, data)
            decoded = time.monotonic() - started
            assert hashlib.sha256(output).hexdigest() == digest(new)
            results.append(dict(source=old.name, target=new.name, algorithm=algorithm,
                                fullBytes=len(target), patchBytes=len(data),
                                encodeSeconds=round(encoded, 3), decodeSeconds=round(decoded, 3)))
            del output, data
        rebuilt.unlink()
    (args.output / 'benchmark.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
