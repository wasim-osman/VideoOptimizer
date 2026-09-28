# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Every entry here
also has a full write-up in [GitHub Releases](https://github.com/wasim-osman/VideoOptimizer/releases).

## [1.8.0] — 2026-09-28

### Added
- The app now remembers how much it's saved you, in total, across every launch — not just
  the current session. Whenever nothing is converting, the window shows something like
  "Lifetime: 4.2 GB saved across 37 files". Persisted in UserDefaults; only ever grows.
  Verified end-to-end with real files: converted one, quit the app, relaunched, converted
  a second, and confirmed the totals accumulated correctly across the restart rather than
  resetting — not just that the underlying arithmetic passed in isolation.

### Fixed
- Opening a video via Finder's "Open With", double-clicking a file with this app set as
  the default handler, or `open -a VideoOptimizer file.mp4` while the app wasn't already
  running could silently do nothing at all. `application(_:openFiles:)` posted a
  notification that `MainViewController` only started listening for in `viewDidAppear()` —
  which is not guaranteed to have run yet on a cold launch triggered by opening a file, so
  the notification could be (and, traced directly, reliably was) posted before anything was
  listening, and silently vanished. Replaced with a direct call from the app delegate to
  the view controller, buffered for the narrow case where even that doesn't exist yet.
  Found while building real end-to-end tests for the feature above, not reported separately.

## [1.7.0] — 2026-09-27

### Fixed
- Cancelling a conversion, then dropping another file, did nothing. The drop-deduplication
  check treated any file already seen in the queue as permanently handled, regardless of
  whether it succeeded, failed, or was cancelled — so cancelling a file silently blocked
  that exact file from ever being converted again in the same session. The dedup now only
  considers jobs still actually in flight (queued/probing/planning/encoding); a job in any
  terminal state no longer blocks a re-drop. Verified with two new integration tests
  against the real pipeline (real ffmpeg, no stub).

## [1.6.0] — 2026-09-27

### Changed
- "Use the Apple media engine" is now greyed out whenever AV1 is selected as the codec.
  There's no hardware AV1 encoder on Apple Silicon, so the checkbox would do nothing if
  checked with AV1 chosen — v1.5.0 already made the encoder fall back to software
  correctly, this makes the UI stop implying otherwise. Disabled, not force-unchecked:
  switching back to H.264/HEVC/Auto restores whatever was checked before.

## [1.5.0] — 2026-09-27

### Fixed
- "Use the Apple media engine" did nothing in Smallest mode. Only Balanced mode ever read
  that setting — Smallest ignored it entirely, so checking it and picking HEVC just
  swapped one software encoder (AV1) for another (x265), both still fully CPU-bound.
  Smallest + hardware now actually uses `hevc_videotoolbox` (or `h264_videotoolbox` for an
  explicit H.264 choice). An explicit AV1 choice still always stays software — there is no
  hardware AV1 encoder on Apple Silicon to route to.

## [1.4.0] — 2026-09-25

### Fixed
- Quitting mid-encode (⌘Q or closing the window) used to orphan the ffmpeg child process —
  it kept running in the background, reparented to `launchd`, with nothing left able to
  show its progress or cancel it, and its output could never be promoted from `.part` to a
  finished file (that step runs in the app, not in ffmpeg). The app now warns before
  quitting with an active job, and on confirmation actually stops it first.

### Added
- A visible Stop button in the drop zone's corner (opposite Settings), shown only while
  something is converting. The File ▸ Stop Converting menu item and ⌘. still work too.

### Changed
- ffmpeg's child-process QoS: `.userInitiated` → `.utility`. A multi-hour encode competing
  at interactive scheduling priority is how it ends up starving the app's own UI thread —
  including the controls meant to stop it — under heavy load.

## [1.3.0] — 2026-09-25

### Fixed
- A second file dropped while one was already converting was queued correctly underneath,
  but nothing on screen showed its filename until it became the active job — indistinguishable
  from the drop having done nothing. The status line now names whatever's waiting
  ("next: b.mp4", or "+N" beyond that).

### Added
- Double-click the window to open a file picker (the same one as File ▸ Open…, ⌘O). A
  single click still reveals the last result in Finder; the two are told apart by the
  system's own double-click interval so one doesn't also trigger the other.

## [1.2.0] — 2026-09-24

### Added
- A real app icon: "Outline Precision" — a thin ink ring and V-shaped chevron on a warm
  paper ground — chosen from six concepts after a design review.
  [`scripts/generate-app-icon.swift`](scripts/generate-app-icon.swift) renders all ten
  sizes macOS needs directly from the vector geometry, with the stroke weight
  optically corrected per size so it stays a hairline at 512px and still reads at 16px.

## [1.1.1] — 2026-09-24

### Added
- A minimalist Settings gear button in the drop zone's corner — no menu bar needed.
- A developer credit line in Settings, linking to the maintainer's GitHub.

## [1.1.0] — 2026-09-24

### Added
- The release DMG now bundles its own ffmpeg, ffprobe, and every shared library they
  depend on (18 libraries total: x264, x265, SVT-AV1, libvpx, dav1d, Opus, libvmaf,
  OpenSSL, LAME), made relocatable by
  [`scripts/bundle-runtime.py`](scripts/bundle-runtime.py) — no Homebrew or system ffmpeg
  required any more. `package.sh --no-ffmpeg` still produces the smaller, non-bundled DMG.
- `THIRD_PARTY_LICENSES.md` + [`licenses/`](licenses/): every bundled component's exact
  licence text, version, and upstream source, since bundling a GPL-enabled ffmpeg carries
  redistribution obligations regardless of link style.

## [1.0.0] — 2026-09-24

Initial public release. A native macOS drag-and-drop video optimiser for Apple Silicon:
drop a file and it's re-encoded to the smallest file that's visually indistinguishable
from the source. Pre-flight and post-flight guards against ever producing a larger file,
a resolution- and content-aware CRF ladder, full colour/HDR/audio/subtitle/chapter
preservation, and Fast/Balanced/Smallest modes. 94 tests. Required a system ffmpeg
(`brew install ffmpeg`); unsigned DMG.

[1.7.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.7.0
[1.6.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.6.0
[1.5.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.5.0
[1.4.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.4.0
[1.3.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.3.0
[1.2.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.2.0
[1.1.1]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.1.1
[1.1.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.1.0
[1.0.0]: https://github.com/wasim-osman/VideoOptimizer/releases/tag/v1.0.0
