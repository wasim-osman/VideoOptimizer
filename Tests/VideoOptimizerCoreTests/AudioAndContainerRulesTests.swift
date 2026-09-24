// AudioAndContainerRulesTests.swift - Per-track audio decisions (§3.2) and container choice (§3.3).

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("AudioRules")
struct AudioRulesTests {
    private let rules = AudioRules()

    private func stream(_ codec: String, channels: Int = 2, bitrate: Int = 128_000) -> MediaInfo.Audio {
        var a = MediaInfo.Audio()
        a.codecName = codec
        a.channels = channels
        a.bitrate = bitrate
        return a
    }

    @Test("efficient lossy codecs are copied", arguments: ["aac", "opus", "ac3", "eac3"])
    func efficientCodecsAreCopied(codec: String) {
        #expect(rules.action(for: stream(codec), outputContainerIsMKV: false) == .copy,
                "\(codec) is already efficient — re-encoding only loses quality")
    }

    @Test("lossless and bulky codecs are transcoded",
          arguments: ["pcm_s16le", "flac", "alac", "truehd", "dts"])
    func losslessCodecsAreTranscoded(codec: String) {
        let action = rules.action(for: stream(codec), outputContainerIsMKV: false)
        guard case .transcode = action else {
            Issue.record("\(codec) is large and lossless — it must be transcoded, got \(action)")
            return
        }
    }

    @Test("surround gets a higher bitrate than stereo")
    func surroundGetsMoreBits() {
        let stereo = rules.action(for: stream("flac", channels: 2), outputContainerIsMKV: false)
        let surround = rules.action(for: stream("flac", channels: 6), outputContainerIsMKV: false)
        guard case .transcode(_, let stereoRate) = stereo,
              case .transcode(_, let surroundRate) = surround else {
            Issue.record("both should transcode")
            return
        }
        #expect(surroundRate > stereoRate, "5.1 needs more bits than stereo")
    }

    @Test("MKV prefers Opus and MP4 prefers AAC")
    func containerDrivesCodecChoice() {
        guard case .transcode(let mkvCodec, _) = rules.action(for: stream("flac"), outputContainerIsMKV: true),
              case .transcode(let mp4Codec, _) = rules.action(for: stream("flac"), outputContainerIsMKV: false) else {
            Issue.record("both should transcode")
            return
        }
        #expect(mkvCodec == "libopus")
        #expect(mp4Codec == "aac")
    }

    /// Spec §3.2 keeps a lossy track only while it is below 128k per channel;
    /// a wastefully high one is meant to be re-encoded down.
    @Test("a wastefully high bitrate lossy track is not blindly copied")
    func wastefulLossyTrackIsReencoded() {
        // 768k across 2 channels = 384k/channel, far above the 128k/channel rule.
        let action = rules.action(for: stream("ac3", channels: 2, bitrate: 768_000), outputContainerIsMKV: false)
        guard case .transcode = action else {
            Issue.record("§3.2 says >128k/channel should be re-encoded, got \(action)")
            return
        }
    }

    @Test("an unknown bitrate is copied rather than guessed")
    func unknownBitrateIsCopied() {
        #expect(rules.action(for: stream("aac", bitrate: 0), outputContainerIsMKV: false) == .copy)
    }
}

@Suite("ContainerRules")
struct ContainerRulesTests {
    private let rules = ContainerRules()

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/vo-tests/\(name)") }

    @Test("common containers are kept")
    func commonContainersKept() {
        let media = Fixtures.h264_1080p()
        #expect(rules.outputExtension(sourceURL: url("a.mp4"), media: media) == "mp4")
        #expect(rules.outputExtension(sourceURL: url("a.mov"), media: media) == "mov")
        #expect(rules.outputExtension(sourceURL: url("a.mkv"), media: media) == "mkv")
    }

    @Test("legacy containers are modernised to MP4",
          arguments: ["avi", "wmv", "flv", "mpg", "ts", "vob"])
    func legacyContainersBecomeMP4(ext: String) {
        #expect(rules.outputExtension(sourceURL: url("a.\(ext)"), media: Fixtures.h264_1080p()) == "mp4")
    }

    @Test("bitmap subtitles force MKV because MP4 cannot carry them")
    func bitmapSubtitlesForceMKV() {
        var media = Fixtures.h264_1080p()
        Fixtures.addSubtitle(&media, codec: "hdmv_pgs_subtitle")
        #expect(rules.outputExtension(sourceURL: url("a.mp4"), media: media) == "mkv")
    }

    @Test("TrueHD forces MKV")
    func trueHDForcesMKV() {
        var media = Fixtures.h264_1080p()
        Fixtures.addAudio(&media, codec: "truehd", channels: 8, bitrate: 4_000_000)
        #expect(rules.outputExtension(sourceURL: url("a.mp4"), media: media) == "mkv")
    }

    @Test("a container change is reported accurately")
    func containerChangeReporting() {
        let media = Fixtures.h264_1080p()
        #expect(rules.decision(sourceURL: url("a.mp4"), media: media).changed == false)
        #expect(rules.decision(sourceURL: url("a.avi"), media: media).changed == true)
        #expect(rules.decision(sourceURL: url("a.MP4"), media: media).changed == false,
                "a case difference in the source extension is not a container change")
    }

    @Test("MP4 subtitles become mov_text")
    func mp4SubtitlesBecomeMovText() {
        #expect(rules.subtitleCodec(for: "mp4", sourceCodec: "subrip") == "mov_text")
        #expect(rules.subtitleCodec(for: "mov", sourceCodec: "ass") == "mov_text")
    }

    @Test("MKV copies the subtitles it can hold")
    func mkvCopiesSubtitles() {
        #expect(rules.subtitleCodec(for: "mkv", sourceCodec: "subrip") == "copy")
        #expect(rules.subtitleCodec(for: "mkv", sourceCodec: "hdmv_pgs_subtitle") == "copy",
                "bitmap subtitles cannot be converted to text — they must be copied")
    }
}
