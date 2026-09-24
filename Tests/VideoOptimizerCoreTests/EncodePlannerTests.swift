// EncodePlannerTests.swift - MediaInfo + Settings -> ffmpeg argument array (spec §2, §3).
//
// The planner is pure, so almost every one of these runs without ffmpeg or any file on disk.

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("EncodePlanner")
struct EncodePlannerTests {
    private let planner = EncodePlanner()

    private func plan(_ media: MediaInfo, _ mutate: (inout Settings) -> Void = { _ in }) -> EncodePlan {
        var settings = Settings()
        mutate(&settings)
        return planner.plan(media: media, settings: settings)
    }

    // MARK: - Outcome gating

    @Test("a bloated source is planned")
    func bloatedSourceIsPlanned() {
        let result = plan(Fixtures.h264_1080p())
        #expect(result.outcome == .planned)
        #expect(result.arguments.isEmpty == false)
    }

    @Test("an efficient source is refused without an ffmpeg command")
    func efficientSourceIsRefused() {
        let result = plan(Fixtures.efficientHEVC())
        guard case .alreadyOptimized = result.outcome else {
            Issue.record("an efficient source must be refused")
            return
        }
        #expect(result.arguments.isEmpty, "a refused job must not carry an ffmpeg command")
    }

    // MARK: - Stream mapping

    @Test("every audio track is mapped when audio is kept")
    func allAudioTracksMapped() {
        var media = Fixtures.h264_1080p()
        Fixtures.addAudio(&media, codec: "ac3", channels: 6, bitrate: 640_000)
        let args = plan(media) { $0.keepAudio = true }.arguments
        #expect(args.values(after: "-map").filter { $0.hasPrefix("0:a") } == ["0:a:0", "0:a:1"])
    }

    /// "Keep audio: off" must mean no audio at all.
    @Test("no audio is mapped when audio is disabled")
    func noAudioWhenDisabled() {
        let args = plan(Fixtures.h264_1080p()) { $0.keepAudio = false }.arguments
        let audioMaps = args.values(after: "-map").filter { $0.hasPrefix("0:a") }
        #expect(audioMaps.isEmpty, "keepAudio = false must drop every audio track, mapped \(audioMaps)")
    }

    @Test("subtitles are mapped only when kept")
    func subtitlesMappedOnlyWhenKept() {
        var media = Fixtures.h264_1080p()
        Fixtures.addSubtitle(&media, codec: "subrip")
        let kept = plan(media) { $0.keepSubtitles = true }.arguments
        let dropped = plan(media) { $0.keepSubtitles = false }.arguments
        #expect(kept.values(after: "-map").filter { $0.hasPrefix("0:s") } == ["0:s:0"])
        #expect(dropped.values(after: "-map").filter { $0.hasPrefix("0:s") }.isEmpty)
    }

    @Test("the video stream is always mapped first")
    func videoMappedFirst() {
        #expect(plan(Fixtures.h264_1080p()).arguments.values(after: "-map").first == "0:v:0")
    }

    // MARK: - Conflict policy

    @Test("skip policy stops when the output already exists")
    func skipPolicyStops() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vo-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("clip.mp4")
        try Data("source".utf8).write(to: source)
        try Data("already here".utf8).write(to: dir.appendingPathComponent("clip_optimized.mp4"))

        let result = plan(Fixtures.h264_1080p(path: source.path)) {
            $0.conflictPolicy = .skip
            $0.outputResolution = .source   // the default; skip must work here too
        }

        #expect(result.outcome != .planned, "skip policy must not plan an encode over an existing output")
        #expect(result.arguments.isEmpty)
    }

    // MARK: - Encoder selection

    @Test("balanced software mode uses x265 at the 1080p rung")
    func balancedUsesX265() {
        // 6 Mbit/s at 1080p30 is 0.097 bpp — under the grain threshold, so this
        // reads the ladder rung directly with no content adjustment.
        let args = plan(Fixtures.h264_1080p(bitrate: 6_000_000)) { $0.encoderMode = .balanced }.arguments
        #expect(args.value(after: "-c:v") == "libx265")
        #expect(args.value(after: "-crf") == "21")
    }

    /// Pins the grain threshold, which is easy to shift by accident: anything above
    /// 2x the codec's norm BPP is treated as grainy and given +2 CRF. Note this
    /// catches ordinary high-bitrate camera footage too (12 Mbit/s 1080p = 0.19 bpp).
    @Test("a high-bitrate source is treated as grainy and spends fewer bits")
    func grainySourceGetsHigherCRF() {
        let ordinary = plan(Fixtures.h264_1080p(bitrate: 6_000_000)) { $0.encoderMode = .balanced }
        let grainy = plan(Fixtures.h264_1080p(bitrate: 12_000_000)) { $0.encoderMode = .balanced }
        let ordinaryCRF = Int(ordinary.arguments.value(after: "-crf") ?? "0") ?? 0
        let grainyCRF = Int(grainy.arguments.value(after: "-crf") ?? "0") ?? 0
        #expect(grainyCRF == ordinaryCRF + 2)
    }

    @Test("an explicit H.264 choice is honoured")
    func explicitH264Honoured() {
        let args = plan(Fixtures.h264_1080p()) {
            $0.encoderMode = .balanced
            $0.codecChoice = .h264
        }.arguments
        #expect(args.value(after: "-c:v") == "libx264")
    }

    /// Choosing a codec in Settings must actually change the encoder.
    @Test("an explicit AV1 choice is honoured")
    func explicitAV1Honoured() {
        let encoder = plan(Fixtures.h264_1080p()) {
            $0.encoderMode = .balanced
            $0.codecChoice = .av1
        }.arguments.value(after: "-c:v") ?? ""
        #expect(encoder.contains("av1"), "codecChoice = .av1 must select an AV1 encoder, got \(encoder)")
    }

    @Test("an explicit HEVC choice is honoured")
    func explicitHEVCHonoured() {
        let encoder = plan(Fixtures.h264_1080p()) {
            $0.encoderMode = .balanced
            $0.codecChoice = .hevc
        }.arguments.value(after: "-c:v") ?? ""
        #expect(encoder.contains("265") || encoder.contains("hevc"),
                "codecChoice = .hevc must select an HEVC encoder, got \(encoder)")
    }

    // MARK: - VideoToolbox quality direction
    //
    // hevc_videotoolbox's -q:v runs 0…100 with HIGHER meaning better quality
    // (verified: q=65 produced a larger file than q=50). The mode labels must
    // therefore order as Fast <= Balanced on that scale.

    @Test("VideoToolbox quality orders Fast no higher than Balanced")
    func videoToolboxQualityDirection() throws {
        let fastArgs = plan(Fixtures.h264_1080p()) { $0.encoderMode = .fast }.arguments
        let balancedArgs = plan(Fixtures.h264_1080p()) {
            $0.encoderMode = .balanced
            $0.useHardwareEncoder = true
        }.arguments

        let fastQ = try #require(fastArgs.value(after: "-q:v").flatMap(Int.init))
        let balancedQ = try #require(balancedArgs.value(after: "-q:v").flatMap(Int.init))
        #expect(fastQ <= balancedQ,
                "higher -q:v is better quality, so Fast (\(fastQ)) must not exceed Balanced (\(balancedQ))")
    }

    @Test("hardware modes do not emit a CRF")
    func hardwareModesHaveNoCRF() {
        let args = plan(Fixtures.h264_1080p()) { $0.encoderMode = .fast }.arguments
        #expect(args.contains("-crf") == false, "VideoToolbox has no CRF control")
    }

    // MARK: - Colour and HDR

    @Test("colour tags are propagated")
    func colourTagsPropagated() {
        let args = plan(Fixtures.h264_1080p()).arguments
        #expect(args.value(after: "-color_primaries") == "bt709")
        #expect(args.value(after: "-color_trc") == "bt709")
        #expect(args.value(after: "-colorspace") == "bt709")
        #expect(args.value(after: "-color_range") == "tv")
    }

    /// ffmpeg honours only the LAST -x265-params, so tuning and HDR10 must be merged.
    @Test("-x265-params appears exactly once with HDR merged into it")
    func x265ParamsMergedOnce() {
        let args = plan(Fixtures.hevc_hdr10_2160p()) {
            $0.encoderMode = .balanced
            $0.useHardwareEncoder = false
        }.arguments

        #expect(args.occurrences(of: "-x265-params") == 1,
                "a second -x265-params would silently discard the first")
        let params = args.value(after: "-x265-params") ?? ""
        #expect(params.contains("hdr10=1"), "HDR10 flag missing from \(params)")
        #expect(params.contains("master-display="), "mastering display missing from \(params)")
        #expect(params.contains("aq-mode"), "tuning was lost when HDR was merged in")
    }

    @Test("an SDR source gets no HDR parameters")
    func sdrGetsNoHDRParams() {
        let params = plan(Fixtures.h264_1080p()) { $0.encoderMode = .balanced }
            .arguments.value(after: "-x265-params") ?? ""
        #expect(params.contains("hdr10=1") == false, "SDR content must never be tagged HDR10")
        #expect(params.contains("master-display=") == false)
    }

    @Test("HEVC in MP4 carries the hvc1 tag")
    func hevcCarriesHvc1() {
        let args = plan(Fixtures.h264_1080p()) { $0.encoderMode = .balanced }.arguments
        #expect(args.value(after: "-tag:v") == "hvc1",
                "HEVC in MP4 without hvc1 will not play in QuickTime")
    }

    // MARK: - Hardware decode vs software filters

    /// `-hwaccel_output_format videotoolbox` keeps frames on the GPU. Software filters
    /// such as scale and yadif cannot read those without an explicit hwdownload.
    @Test("hardware surfaces are not combined with software filters")
    func hwSurfacesVsSoftwareFilters() {
        let args = plan(Fixtures.hevc_hdr10_2160p()) {
            $0.encoderMode = .balanced
            $0.useHardwareEncoder = false
            $0.outputResolution = .p1080      // forces a scale filter
        }.arguments

        let filters = args.value(after: "-vf") ?? ""
        guard args.value(after: "-hwaccel_output_format") == "videotoolbox", !filters.isEmpty else { return }
        #expect(filters.contains("hwdownload") || filters.contains("_vt"),
                "software filter '\(filters)' cannot read GPU surfaces without hwdownload")
    }

    /// nv12 is an 8-bit format — using it to ingest a 10-bit source throws away a bit depth
    /// the very next argument (-pix_fmt yuv420p10le) asks for.
    @Test("a 10-bit source is not downconverted by the decode format")
    func tenBitNotDownconverted() {
        var media = Fixtures.h264_1080p()
        media.video.pixFmt = "yuv420p10le"
        media.video.bitDepth = 10

        let args = plan(media) {
            $0.encoderMode = .balanced
            $0.alwaysUse10Bit = true
        }.arguments

        if args.value(after: "-pix_fmt") == "yuv420p10le" {
            #expect(args.value(after: "-hwaccel_output_format") != "nv12",
                    "nv12 is 8-bit; a 10-bit source would be truncated then padded back")
        }
    }

    /// The nv12/p010 download formats are 4:2:0 only. Requesting one from a 4:2:2 or
    /// 4:4:4 source makes the VideoToolbox decoder fail the entire encode with
    /// "Unsupported or mismatching pixel format" — verified against ffmpeg 8.x.
    @Test("hardware decode is skipped for chroma layouts it cannot produce",
          arguments: ["yuv444p", "yuv422p", "yuvj444p", "yuv422p10le", "gbrp"])
    func hwDecodeSkippedForUnsupportedChroma(pixFmt: String) {
        var media = Fixtures.h264_1080p()
        media.video.pixFmt = pixFmt

        let args = plan(media) { $0.encoderMode = .balanced }.arguments
        #expect(args.contains("-hwaccel") == false,
                "\(pixFmt) cannot be decoded into nv12/p010 — decode in software instead")
    }

    @Test("hardware decode is used for ordinary 4:2:0 sources",
          arguments: ["yuv420p", "yuv420p10le", "nv12"])
    func hwDecodeUsedFor420(pixFmt: String) {
        var media = Fixtures.h264_1080p()
        media.video.pixFmt = pixFmt

        let args = plan(media) { $0.encoderMode = .balanced }.arguments
        #expect(args.value(after: "-hwaccel") == "videotoolbox")
    }

    // MARK: - Container flags

    @Test("MP4 output gets faststart")
    func mp4GetsFaststart() {
        #expect((plan(Fixtures.h264_1080p()).arguments.value(after: "-movflags") ?? "").contains("faststart"))
    }

    /// -movflags belongs to the MOV/MP4 muxer; Matroska silently ignores it.
    @Test("Matroska output carries no -movflags")
    func matroskaHasNoMovFlags() {
        var media = Fixtures.h264_1080p(path: "/tmp/vo-tests/sample.mkv")
        Fixtures.addSubtitle(&media, codec: "hdmv_pgs_subtitle")   // forces mkv
        #expect(plan(media).arguments.contains("-movflags") == false,
                "-movflags is a no-op on Matroska and contradicts -map_chapters")
    }

    // MARK: - Resolution

    @Test("a downscale produces a scale filter")
    func downscaleProducesFilter() {
        let args = plan(Fixtures.h264_1080p()) { $0.outputResolution = .p720 }.arguments
        #expect((args.value(after: "-vf") ?? "").contains("720"))
    }

    @Test("an upscale is never requested")
    func upscaleNeverRequested() {
        var media = Fixtures.h264_1080p()
        media.video.width = 1280
        media.video.height = 720
        let args = plan(media) { $0.outputResolution = .p2160 }.arguments
        #expect(args.value(after: "-vf") == nil, "a 720p source must never be upscaled to 2160p")
    }

    // MARK: - Command hygiene

    @Test("the output path is the final argument")
    func outputPathIsLast() {
        let result = plan(Fixtures.h264_1080p())
        #expect(result.arguments.last == result.outputURL.path)
    }

    @Test("the machine-readable progress stream is requested")
    func progressStreamRequested() {
        let args = plan(Fixtures.h264_1080p()).arguments
        #expect(args.value(after: "-progress") == "pipe:1")
        #expect(args.contains("-nostats"))
    }

    @Test("arguments are passed raw, never shell-quoted")
    func argumentsAreNotShellQuoted() {
        let media = Fixtures.h264_1080p(path: "/tmp/vo tests/a film (2024) 'final'.mp4")
        let result = plan(media)
        for argument in result.arguments {
            #expect(argument.hasPrefix("\"") == false, "arguments must be passed raw, never shell-quoted")
            #expect(argument.hasPrefix("'") == false)
        }
        #expect(result.arguments.contains(media.format.filename),
                "the input path must be passed as one unsplit argument")
    }

    @Test("extra arguments are split into separate tokens")
    func extraArgumentsSplit() {
        let args = plan(Fixtures.h264_1080p()) { $0.extraArguments = "-an -sn" }.arguments
        #expect(args.contains("-an"))
        #expect(args.contains("-sn"))
    }
}
