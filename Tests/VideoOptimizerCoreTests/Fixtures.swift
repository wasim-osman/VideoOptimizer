// Fixtures.swift - MediaInfo builders for the pure planning tests.
//
// Every value here is modelled on real ffprobe output so the planner is exercised
// with the shapes it will actually see.

import Foundation
@testable import VideoOptimizerCore

enum Fixtures {
    /// A typical over-bitrate 1080p H.264 MP4 — the archetypal "worth optimising" input.
    static func h264_1080p(
        path: String = "/tmp/vo-tests/sample.mp4",
        bitrate: Int = 12_000_000,
        fps: Double = 30,
        audioCodec: String = "aac",
        audioChannels: Int = 2
    ) -> MediaInfo {
        var m = MediaInfo()
        m.video.codecName = "h264"
        m.video.width = 1920
        m.video.height = 1080
        m.video.bitrate = bitrate
        m.video.fps = fps
        m.video.avgFrameRate = "30/1"
        m.video.rFrameRate = "30/1"
        m.video.pixFmt = "yuv420p"
        m.video.bitDepth = 8
        m.video.colorPrimaries = "bt709"
        m.video.colorTransfer = "bt709"
        m.video.colorSpace = "bt709"
        m.video.colorRange = "tv"
        m.video.duration = 600

        var a = MediaInfo.Audio()
        a.codecName = audioCodec
        a.channels = audioChannels
        a.bitrate = 128_000
        a.sampleRate = 48_000
        m.audios = [a]

        m.format.filename = path
        m.format.formatName = "mov,mp4,m4a,3gp,3g2,mj2"
        m.format.duration = 600
        m.format.size = 900_000_000
        m.format.bitrate = 12_128_000
        return m
    }

    /// An HDR10 HEVC source: PQ transfer plus both metadata blocks present.
    static func hevc_hdr10_2160p(path: String = "/tmp/vo-tests/hdr.mkv") -> MediaInfo {
        var m = MediaInfo()
        m.video.codecName = "hevc"
        m.video.width = 3840
        m.video.height = 2160
        m.video.bitrate = 60_000_000
        m.video.fps = 24
        m.video.avgFrameRate = "24/1"
        m.video.rFrameRate = "24/1"
        m.video.pixFmt = "yuv420p10le"
        m.video.bitDepth = 10
        m.video.colorPrimaries = "bt2020"
        m.video.colorTransfer = "smpte2084"
        m.video.colorSpace = "bt2020nc"
        m.video.colorRange = "tv"
        m.video.isHDR = true
        m.video.hasMasteringDisplay = true
        m.video.hasContentLight = true
        m.video.masteringDisplay = "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
        m.video.maxCLL = "1000,400"
        m.video.duration = 7200

        m.format.filename = path
        m.format.duration = 7200
        m.format.size = 54_000_000_000
        m.format.bitrate = 60_000_000
        return m
    }

    /// An already-efficient source: BPP below the codec floor, so it must be refused.
    static func efficientHEVC(path: String = "/tmp/vo-tests/tiny.mp4") -> MediaInfo {
        var m = h264_1080p(path: path)
        m.video.codecName = "hevc"
        // 1920*1080*30 = 62.2M pixels/s; 0.020 bpp target -> ~1.24 Mbit/s
        m.video.bitrate = 1_200_000
        m.format.bitrate = 1_200_000
        return m
    }

    /// A source whose bitrate ffprobe could not determine at any level.
    /// Happens with some MKV / streamed inputs where duration is also absent.
    static func unknownBitrate(path: String = "/tmp/vo-tests/unknown.mkv") -> MediaInfo {
        var m = h264_1080p(path: path)
        m.video.bitrate = 0
        m.format.bitrate = 0
        m.format.duration = 0
        m.format.size = 0
        m.video.duration = 0
        return m
    }

    static func addSubtitle(_ m: inout MediaInfo, codec: String, language: String = "eng") {
        var s = MediaInfo.Subtitle()
        s.index = m.subtitles.count
        s.codecName = codec
        s.language = language
        m.subtitles.append(s)
    }

    static func addAudio(_ m: inout MediaInfo, codec: String, channels: Int, bitrate: Int) {
        var a = MediaInfo.Audio()
        a.index = m.audios.count
        a.codecName = codec
        a.channels = channels
        a.bitrate = bitrate
        m.audios.append(a)
    }
}

// MARK: - Argument-array helpers
//
// The planner emits a flat [String]. These read it the way ffmpeg does, so a test
// asserting "-crf 21" cannot be fooled by the value belonging to a different flag.

extension Array where Element == String {
    /// The value immediately following `flag`, or nil when the flag is absent.
    func value(after flag: String) -> String? {
        guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
        return self[i + 1]
    }

    /// Every value following each occurrence of `flag` (e.g. all `-map` targets).
    func values(after flag: String) -> [String] {
        var result: [String] = []
        for (i, element) in enumerated() where element == flag && i + 1 < count {
            result.append(self[i + 1])
        }
        return result
    }

    func contains(flag: String) -> Bool { contains(flag) }

    /// Count of a flag's occurrences — ffmpeg silently honours only the last of some
    /// options, so "appears exactly once" is a real correctness property.
    func occurrences(of flag: String) -> Int {
        filter { $0 == flag }.count
    }
}
