// EncoderCapabilities.swift - Parses `ffmpeg -hide_banner -encoders` once at launch (spec §2.4).

import Foundation

public struct EncoderCapabilities: Sendable, Equatable {
    public var encoders: [String] = []

    public init(binaryPath: String = BinaryLocator.ffmpegPath()) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-hide_banner", "-encoders"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let _ = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            self.encoders = Self.parse(text)
        } catch {
            self.encoders = []
        }
    }

    public static func parse(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 2 else { continue }
            // Lines look like:  V....D libx265  libx265 H.265 / HEVC (codec hevc)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.first?.isLetter == true else { continue }
            names.append(name)
        }
        return names
    }

    public func has(_ codec: String) -> Bool {
        encoders.contains { $0 == codec }
    }

    /// Whether a hardware AV1 encoder has appeared since this system's silicon (spec §2.4).
    public var hasAV1VideoToolbox: Bool { has("av1_videotoolbox") }

    public var hasSVT: Bool { has("libsvtav1") }
    public var hasX265: Bool { has("libx265") }
    public var hasX264: Bool { has("libx264") }
    public var hasHEVCVideoToolbox: Bool { has("hevc_videotoolbox") }

    /// Choose the best AV1-capable method: hardware if present, else SVT, else nil.
    public func av1Encoder() -> String? {
        if hasAV1VideoToolbox { return "av1_videotoolbox" }
        if hasSVT { return "libsvtav1" }
        return nil
    }
}