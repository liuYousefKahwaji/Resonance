# Measured APK patch results

Real, previously signed Resonance APKs were compared on this Windows PC on
2026-10-01. Every reconstructed output matched the target APK's SHA-256 exactly.
Timings are host measurements under concurrent Flutter builds; they are not
phone-speed guarantees. Full results: benchmark-results.json.

| APK transition | Full bytes | xdelta bytes | Zstd patch-from bytes | bsdiff bytes |
| --- | ---: | ---: | ---: | ---: |
| 3.4.1 → 3.4.2 | 46,914,229 | 6,446,435 | 6,443,745 | 6,476,046 |
| 3.4.2 → 3.4.3 | 46,928,169 | 4,396,996 | 4,373,028 | 4,384,185 |
| 3.4.3 → 3.4.4 | 46,934,865 | 4,354,524 | 4,355,936 | 4,375,296 |

The latest pair needs **90.7% fewer downloaded bytes** with xdelta. Zstandard
is competitive; an earlier experiment using a Python raw reference dictionary
was not real `--patch-from` and is excluded from this comparison.

Chosen codec: xdelta 3.2.1, commit
`2c36417e6d09bf700d3d1cca44ed3e42101016c3`, Apache-2.0. Encoder uses no secondary
compression, 16 MiB source window, 8 MiB target window. The app embeds a decoder
with a 16 MiB hard window cap and 64 KiB IO blocks. Encoding was much quicker
than Zstd level 19 / bsdiff in these samples, with essentially the same sizes.

The shipped decoder reconstructed 3.4.3 → 3.4.4 in 0.237 seconds, with a sampled
Windows peak working set of 25,268,224 bytes (~24.1 MiB). This includes the host
decoder process, not the Flutter app. JNI uses that same core on Android; real
phone latency and memory still require measurement on representative devices.

Comparison versions: Zstandard 1.5.7 at
`f8745da6ff1ad1e7bab384bd1f9d742439278e99`, actual CLI `-19 --patch-from`; Python
bsdiff4 1.2.6. Zstd is a benchmark dependency, not shipped in Resonance.

Reproduce after building the pinned xdelta CLI and shipped decoder:

```powershell
./build/release-tools-venv/Scripts/python.exe -m pip install bsdiff4==1.2.6
./build/release-tools-venv/Scripts/python.exe tool/release/benchmark_apk.py --xdelta build/update-tools/xdelta-host/Release/xdelta3.exe --decoder build/update-tools/decoder/Release/resonance-patch.exe --zstd PATH_TO_ZSTD_1_5_7 --output build/apk-benchmark release/v3.4.1/resonance-v3.4.1.apk release/v3.4.2/resonance-v3.4.2.apk release/v3.4.3/resonance-v3.4.3.apk release/v3.4.4/resonance-v3.4.4.apk
```

Use measure_decoder.py for Windows peak working set. Run the isolated Android
lab described in README.md to measure preparation on an emulator/phone.

Tests in tests/test_decoder.py cover exact reconstruction, truncated patches,
wrong sources, and output limits. Set RESONANCE_TEST_XDELTA and
RESONANCE_TEST_DECODER to their executable paths, then run unittest discovery.

Patch savings vary with changed code, Flutter/NDK/plugin versions, compression,
and the distance between releases. CI omits patches at least 70% of full size;
the signed full APK/Windows ZIP remains available for every release.
