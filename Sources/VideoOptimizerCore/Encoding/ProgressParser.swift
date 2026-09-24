// ProgressParser.swift - Parses `-progress pipe:1 -nostats` key/value blocks (spec §3.4).

import Foundation

public struct ProgressSnapshot: Sendable, Equatable {
    public var frame: Int = 0
    public var fps: Double = 0
    public var outTimeMicros: Double = 0
    public var speed: Double = 0
    public var done: Bool = false

    public init() {}

    /// Percent complete against a known duration (spec §3.4).
    public func percent(duration: Double) -> Double {
        guard duration > 0 else { return done ? 1 : 0 }
        return min(max(outTimeMicros / (duration * 1_000_000), 0), 1)
    }
}

/// Accumulates key/value blocks from stdout. Caller feeds lines; `latest` is the last complete block.
public struct ProgressParser: Sendable {
    private var currentBlock: [String: String] = [:]
    public private(set) var latest: ProgressSnapshot = ProgressSnapshot()

    public init() {}

    public mutating func feed(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }

        let key = String(parts[0])
        currentBlock[key] = String(parts[1])

        // ffmpeg terminates every block with `progress=continue` or `progress=end`.
        // The stream contains no blank lines, so that key is the only block delimiter.
        if key == "progress" { commit() }
    }

    private mutating func commit() {
        var snap = ProgressSnapshot()
        if let f = currentBlock["frame"], let value = Int(f) { snap.frame = value }
        if let f = currentBlock["fps"], let value = Double(f) { snap.fps = value }
        if let t = currentBlock["out_time_us"], let value = Double(t) { snap.outTimeMicros = value }
        if let s = currentBlock["speed"],
           let value = Double(s.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)) {
            snap.speed = value
        }
        snap.done = currentBlock["progress"] == "end"
        latest = snap
        currentBlock = [:]
    }
}