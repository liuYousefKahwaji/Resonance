# QuickJS-NG runtime

`arm64-v8a/libresonance_qjs.so` is the QuickJS-NG `qjs` command-line
runtime, built for Android API 24 / arm64-v8a from QuickJS-NG v0.16.2
(commit `1ab8676f4b6d6d669baeb5f21790fb9734636a20`). It is deliberately named
as an Android native library so the package manager extracts it to the app's
read-only, executable native-library directory.

Source: https://github.com/quickjs-ng/quickjs/tree/v0.16.2

Binary SHA-256:
`EC278CCB9CB2923D09C72030AF61A7982FA043ED7FDE0E3D3D3EF3B8437A0F12`

## License

The MIT License (MIT)

Copyright (c) 2017-2026 Fabrice Bellard
Copyright (c) 2017-2024 Charlie Gordon
Copyright (c) 2023-2026 Ben Noordhuis
Copyright (c) 2023-2026 Saúl Ibarra Corretgé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
