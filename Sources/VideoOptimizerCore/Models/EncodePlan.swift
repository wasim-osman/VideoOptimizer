// EncodePlan.swift - Output of the quality engine.

import Foundation

public enum JobOutcome: Sendable, Codable, Equatable {
    case planned
    case alreadyOptimized(reason: String)
    case sourceTooSmall(reason: String)
}

public struct EncodePlan: Sendable, Codable, Equatable {
    /// Full ffmpeg argument array, excluding the binary path (spec §3: never a shell string).
    public var arguments: [String]
    public var inputURL: URL
    public var outputURL: URL
    public var outcome: JobOutcome
    /// True when the output extension differs from the source extension (spec §3.3).
    public var containerChanged: Bool
    public var crfUsed: Int
    public var encoderUsed: String
    public var estimatedQualityNote: String

    public init(
        arguments: [String] = [],
        inputURL: URL,
        outputURL: URL,
        outcome: JobOutcome = .planned,
        containerChanged: Bool = false,
        crfUsed: Int = 0,
        encoderUsed: String = "",
        estimatedQualityNote: String = ""
    ) {
        self.arguments = arguments
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.outcome = outcome
        self.containerChanged = containerChanged
        self.crfUsed = crfUsed
        self.encoderUsed = encoderUsed
        self.estimatedQualityNote = estimatedQualityNote
    }
}

public enum JobState: String, Sendable, Codable, Equatable {
    case queued
    case probing
    case planning
    case alreadyOptimized
    case encoding
    case succeeded
    case failed
    case cancelled
    case discardedAsBlob   // post-flight bloat guard: output ≥92% of input, discarded
}

public struct Job: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var inputURL: URL
    public var inputSize: Int64
    public var state: JobState
    public var progress: Double          // 0…1
    public var speedText: String = ""
    public var etaText: String = ""
    public var error: String = ""
    public var resultURL: URL?
    public var resultSize: Int64?
    public var mediaInfo: MediaInfo?

    public init(inputURL: URL) {
        self.id = UUID()
        self.inputURL = inputURL
        self.inputSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        self.state = .queued
        self.progress = 0
    }
}