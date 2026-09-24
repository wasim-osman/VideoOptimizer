// Settings.swift - User preferences driving the quality engine (spec §5.2).

import Foundation

public enum EncoderMode: String, Sendable, CaseIterable, Codable {
    case fast
    case balanced
    case smallest
}

public enum CodecChoice: String, Sendable, CaseIterable, Codable {
    case auto
    case h264
    case hevc
    case av1
}

public enum OutputLocation: String, Sendable, CaseIterable, Codable {
    case sameAsSource
    case chooseFolder
    case askEachTime
}

public enum ResolveConflict: String, Sendable, CaseIterable, Codable {
    case overwrite
    case numberIt
    case skip
}

public enum OutputResolution: String, Sendable, CaseIterable, Codable {
    case source
    case p2160
    case p1440
    case p1080
    case p720
    case p480

    public var height: Int? {
        switch self {
        case .source: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

public struct Settings: Sendable, Codable, Equatable {
    public var encoderMode: EncoderMode = .balanced
    public var codecChoice: CodecChoice = .auto
    public var outputResolution: OutputResolution = .source
    public var qualityOffset: Int = 0          // -3…+3 applied on top of the ladder
    public var outputLocation: OutputLocation = .sameAsSource
    public var chosenFolderPath: String = ""
    public var suffix: String = "_optimized"
    public var conflictPolicy: ResolveConflict = .overwrite
    public var keepAudio: Bool = true
    public var keepSubtitles: Bool = true
    public var keepChapters: Bool = true
    public var deleteSource: Bool = false
    public var preserveDates: Bool = true
    public var concurrency: Int = 1
    public var extraArguments: String = ""
    public var analyseForBestSettings: Bool = false   // v1.2 VMAF mode
    public var alwaysUse10Bit: Bool = true

    /// Prefer the Apple media engine (VideoToolbox) for encoding when available.
    /// Hardware HEVC is much faster but produces larger files at equal visual quality.
    public var useHardwareEncoder: Bool = false

    public init() {}
}