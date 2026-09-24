// MediaInfo.swift - Core data model decoded from ffprobe JSON.

import Foundation

public struct MediaInfo: Sendable, Codable, Equatable {
    public struct Video: Sendable, Codable, Equatable {
        public var codecName: String = ""
        public var width: Int = 0
        public var height: Int = 0
        public var bitrate: Int = 0
        public var fps: Double = 0
        public var rFrameRate: String = ""
        public var avgFrameRate: String = ""
        public var pixFmt: String = ""
        public var bitDepth: Int = 8
        public var colorPrimaries: String = ""
        public var colorTransfer: String = ""
        public var colorSpace: String = ""
        public var colorRange: String = ""
        public var fieldOrder: String = "progressive"
        public var rotation: Int = 0
        public var isHDR: Bool = false
        public var hasMasteringDisplay: Bool = false
        public var hasContentLight: Bool = false
        public var masteringDisplay: String = ""
        public var maxCLL: String = ""
        public var sampleAspectRatio: String = ""
        public var duration: Double = 0
        public var isVariableFrameRate: Bool = false
        public var index: Int = 0

        public init() {}
    }

    public struct Audio: Sendable, Codable, Equatable {
        public var index: Int = 0
        public var codecName: String = ""
        public var sampleRate: Int = 0
        public var channels: Int = 2
        public var channelLayout: String = ""
        public var bitrate: Int = 0
        public var language: String = ""
        public var isDefault: Bool = false
        public var isForced: Bool = false

        public init() {}
    }

    public struct Subtitle: Sendable, Codable, Equatable {
        public var index: Int = 0
        public var codecName: String = ""
        public var language: String = ""
        public var isDefault: Bool = false
        public var isForced: Bool = false

        public init() {}
    }

    public struct Format: Sendable, Codable, Equatable {
        public var filename: String = ""
        public var formatName: String = ""
        public var duration: Double = 0
        public var size: Int64 = 0
        public var bitrate: Int = 0
        public var hasChapters: Bool = false
        public var tags: [String: String] = [:]

        public init() {}
    }

    public var video: Video
    public var audios: [Audio]
    public var subtitles: [Subtitle]
    public var format: Format

    public init() {
        self.video = Video()
        self.audios = []
        self.subtitles = []
        self.format = Format()
    }

    /// Bits per pixel per frame — the single most useful derived number (spec §2.1).
    public var bpp: Double {
        guard video.width > 0, video.height > 0, video.fps > 0 else { return 0 }
        return Double(video.bitrate) / Double(video.width * video.height) / video.fps
    }

    public var hasVideo: Bool { video.width > 0 }

    public var containsPGSOrVobSub: Bool {
        subtitles.contains { ["hdmv_pgs_subtitle", "dvd_subtitle"].contains($0.codecName) }
    }

    public var containsTrueHD: Bool {
        audios.contains { ["truehd", "dts", "dts_hd", "dtshd"].contains($0.codecName) }
    }
}