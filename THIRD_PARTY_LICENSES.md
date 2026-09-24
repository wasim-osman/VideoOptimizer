# Third-party licenses

VideoOptimizer's own source (everything under `Sources/` and `Tests/`) is MIT-licensed —
see [LICENSE](LICENSE).

**The DMG release additionally bundles ffmpeg, ffprobe, and their shared libraries**, so
that the app works without requiring Homebrew. Those binaries are separate programs,
unmodified builds of public upstream projects, and are not covered by VideoOptimizer's MIT
licence. This file lists what is bundled, at what version, under what licence, with the
licence's own text alongside it in [`licenses/`](licenses/).

If you build with `./package.sh --no-ffmpeg`, none of this is bundled and the app requires
a system ffmpeg instead (`brew install ffmpeg`) — see the README.

## Why this triggers GPL/LGPL obligations

FFmpeg itself, as bundled here, is built with `--enable-gpl` and links x264 and x265, which
are GPL-2.0-or-later. Distributing that binary means distributing GPL-licensed object code,
which carries obligations independent of how it is linked (statically or, as here,
dynamically): the licence text must accompany the binary, and the corresponding source must
be made available. This project satisfies that by:

- including each project's exact licence text in [`licenses/`](licenses/);
- bundling only pristine, unmodified upstream builds (via Homebrew, at the versions below) —
  no VideoOptimizer-specific patches to any of them;
- pointing at the exact upstream source for every version listed, so the corresponding
  source is a version-controlled tag away, not a request that has to be fulfilled by hand.

If you need the source made available a different way (e.g. shipped alongside a specific
release artifact), open an issue and it will be provided.

## Bundled components

| Component | Version | Licence | Source |
|---|---|---|---|
| [FFmpeg](https://ffmpeg.org/) | 8.1.2 | GPL-2.0-or-later (this build: `--enable-gpl --enable-version3`) | <https://github.com/FFmpeg/FFmpeg/releases/tag/n8.1.2> |
| [x264](https://www.videolan.org/developers/x264.html) | r3222 | GPL-2.0-or-later | <https://code.videolan.org/videolan/x264> |
| [x265](https://github.com/Multicorewareinc/x265) | 4.2 | GPL-2.0-or-later | <https://bitbucket.org/multicoreware/x265_git> |
| [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1) | 4.1.0 | BSD-3-Clause | <https://gitlab.com/AOMediaCodec/SVT-AV1/-/tags> |
| [libvpx](https://www.webmproject.org/code/) | 1.16.0 | BSD-3-Clause | <https://chromium.googlesource.com/webm/libvpx> |
| [dav1d](https://code.videolan.org/videolan/dav1d) | 1.5.4 | BSD-2-Clause | <https://code.videolan.org/videolan/dav1d> |
| [Opus](https://www.opus-codec.org/) | 1.6.1 | BSD-3-Clause | <https://gitlab.xiph.org/xiph/opus> |
| [LAME](https://lame.sourceforge.io/) | 4.0 | LGPL-2.0-or-later | <https://sourceforge.net/projects/lame/> |
| [OpenSSL](https://openssl-library.org) | 3.6.3 | Apache-2.0 | <https://github.com/openssl/openssl> |
| [libvmaf](https://github.com/Netflix/vmaf) | 3.2.0 | BSD-2-Clause-Patent | <https://github.com/Netflix/vmaf> |

Versions and build flags reflect what was actually bundled at release time (as built by the
[Homebrew ffmpeg formula](https://github.com/Homebrew/homebrew-core/blob/master/Formula/f/ffmpeg.rb)
on macOS/arm64) — check `Contents/Resources/bin/ffmpeg -buildconf` inside a given release's
`.app` for that release's exact flags.

## Not bundled

The app does not link, statically or dynamically, against any of the above from Swift code
— `VideoOptimizerCore` shells out to the `ffmpeg`/`ffprobe` executables as separate
processes (see README "Bundling ffmpeg" for why). None of these licences apply to
`Sources/` or `Tests/`.
