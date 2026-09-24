# VideoOptimizer

A native macOS drag-and-drop video optimiser for Apple Silicon.

Drop a video file on the window and it is re-encoded to the smallest file that is
visually indistinguishable from the source, at the source resolution by default.
No dialogs, no settings to get right first.

> **Status:** the encoding core is complete and covered by 94 tests. The app is not yet
> code-signed or notarised, and it does not yet bundle its own ffmpeg — see
> [Installation](#installation) and [Known limitations](#known-limitations).

---

## What makes it different from an ffmpeg wrapper

The quality engine is the product; everything else is plumbing.

**It refuses to make your file worse.** Two independent guards. Before encoding, the source's
bits-per-pixel-per-frame is compared against a floor for its codec — a file already below that
floor is left alone, because re-encoding it would only lose quality. After encoding, if the
result is 92% or more of the original, it is discarded and nothing is written. The most common
failure of "optimiser" apps is quietly producing a *larger* file; that cannot happen here.

**Quality targets are resolution-aware.** CRF is read from a ladder indexed by output height
and encoder, then adjusted for content type, then by your quality offset. 1080p x265 lands on
CRF 21; 2160p on 23, because higher resolutions tolerate more compression for the same
perceived quality.

**It preserves what other tools drop.** Colour primaries, transfer and matrix are copied
verbatim (dropping them is why re-encodes come out washed out). HDR10 mastering-display and
content-light metadata are merged into a single `-x265-params` — ffmpeg honours only the last
one, so a second would silently discard the tuning. Every audio track, subtitle track, chapter
and rotation flag is carried through.

**It picks the container that can hold your streams.** PGS/VobSub subtitles or TrueHD audio
force MKV, because MP4 cannot carry them. Legacy containers are modernised to MP4.

## Modes

| Mode | Encoder | Trade-off |
|---|---|---|
| **Fast** | `hevc_videotoolbox` | Apple media engine. Very fast, larger files. |
| **Balanced** | `libx265` (default) | Software HEVC. The default; best size/quality balance. |
| **Smallest** | `libsvtav1` | AV1. Smallest files, slowest encode. |

Balanced can be switched to the hardware encoder in Settings. Codec can be pinned to
H.264/HEVC/AV1 in any mode.

## Installation

Requires **macOS 14+** on Apple Silicon.

### 1. Install ffmpeg

The app does not bundle ffmpeg yet. It looks for a bundled binary first, then falls back to
`/opt/homebrew/bin`:

```sh
brew install ffmpeg
```

### 2. Install the app

Download the DMG from [Releases](../../releases), open it, and drag VideoOptimizer to
Applications.

Because the app is **not signed with a Developer ID**, macOS will refuse to open it on first
launch. Either right-click the app and choose **Open**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/VideoOptimizer.app
```

This is expected for an unsigned open-source build. If you would rather not trust a binary,
build it yourself — it takes one command.

### Building from source

```sh
git clone https://github.com/wasim-osman/VideoOptimizer.git
cd VideoOptimizer
make package          # builds, tests, and writes dist/VideoOptimizer-1.0.0.dmg
```

Or just run the pieces:

```sh
make build            # swift build
make test             # 94 tests
swift run VideoOptimizerCLI <file> [fast|balanced|smallest] --encode
```

## Usage

Drop one or more video files on the window. Encoding starts immediately; output is written
beside the source as `name_optimized.mp4` unless you choose otherwise in Settings.

- **File ▸ Stop Converting (⌘.)** or **Esc** cancels. ffmpeg is asked to finalise the partial
  file first, then signalled if it does not comply.
- Output is written to `name_optimized.mp4.part` and moved into place only on success, so an
  interrupted encode never leaves a half-written file where a real one should be.
- Click the window after a run to reveal the result in Finder.

## Architecture

```
Sources/
  VideoOptimizerCore/        Headless, no AppKit, no Process in the planning layer
    Probe/                   ffprobe JSON -> MediaInfo
    Planning/                BloatGuard, CRFLadder, Audio/Color/Container rules, EncodePlanner
    Encoding/                FFmpegRunner, JobQueue, ProgressParser
    Quality/                 VMAF search (v1.2)
  VideoOptimizerApp/         AppKit shell: drop zone, settings, job queue wiring
  VideoOptimizerCLI/         Exercises the whole core headlessly
Tests/VideoOptimizerCoreTests/
```

`EncodePlanner.plan(media:settings:)` is a pure function from `MediaInfo` + `Settings` to an
ffmpeg argument array. That purity is why the quality logic is cheap to test: most of the
suite runs without ffmpeg or any file on disk.

Arguments are always passed as an array, never as a shell string, so paths with spaces,
quotes and parentheses need no escaping.

## Testing

```sh
make test             # all 94
make test-planning    # pure logic only, no subprocesses
```

`FFmpegRunner` is tested against a stub `ffmpeg` shell script, so process lifecycle, the
`.part` rename, the post-flight guard and cancellation are all covered without encoding
anything.

Note for contributors: this project is developed on a machine with Apple's Command Line Tools
but no full Xcode, where **XCTest does not exist**. The suite uses swift-testing, and
`Package.swift` passes an explicit `-plugin-path` so its macros resolve without Xcode. If you
have full Xcode installed, that flag is harmless.

## Known limitations

- **No bundled ffmpeg.** The app requires ffmpeg on the system. Bundling a static build is the
  next milestone; see [Bundling ffmpeg](#bundling-ffmpeg).
- **Not signed or notarised.** Needs a paid Apple Developer ID. Until then, Gatekeeper will
  warn on first launch.
- **Downscaling uses `scale`, not `zscale`.** zscale gives better resampling and dithering but
  requires libzimg, which many ffmpeg builds (including Homebrew's) omit — emitting it there
  fails the encode outright with "Filter not found".
- **Hardware decode is skipped for 4:2:2 / 4:4:4 sources.** VideoToolbox cannot download those
  into the NV12/P010 formats the filters need, so they decode in software. Correct, just slower.
- **The grain classifier is aggressive.** Anything above 2× the codec's norm bitrate is treated
  as grainy and given +2 CRF, which at 1080p30 catches ordinary high-bitrate camera footage.

## Bundling ffmpeg

The app deliberately invokes `ffmpeg` as a **separate process** rather than linking `libav*`.
That keeps this project's MIT-licensed Swift source clearly separate from ffmpeg's licence,
and it buys process isolation (a malformed file crashes the child, not the app), trivial
cancellation, and a machine-readable progress stream.

To make a build self-contained, drop statically linked `ffmpeg` and `ffprobe` binaries into
`VideoOptimizer.app/Contents/Resources/bin/`. `BinaryLocator` prefers them over the system
copies.

**If you distribute such a build**, note that a quality-first ffmpeg includes x264 and x265,
which are GPL. Redistributing those binaries carries GPL obligations: publish the build script
and a written offer for the corresponding source. This is also why the app cannot ship on the
Mac App Store.

## Licence

MIT — see [LICENSE](LICENSE).

ffmpeg is a separate program invoked at runtime and is **not** covered by this licence. It
carries its own (LGPL or GPL depending on how it was built).
