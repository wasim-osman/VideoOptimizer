// BinaryLocator.swift - Resolves the bundled ffmpeg/ffprobe, falling back to system (spec §0.2, §8.6).

import Foundation

public struct BinaryLocator: Sendable {
    public static func bundledBinDir() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin"),
            Bundle.main.resourceURL?.appendingPathComponent("bin"),
            URL(fileURLWithPath: "Resources/bin", isDirectory: true),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    public static func ffmpegPath() -> String {
        if let dir = bundledBinDir(),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("ffmpeg").path) {
            return dir.appendingPathComponent("ffmpeg").path
        }
        return "/opt/homebrew/bin/ffmpeg"
    }

    public static func ffprobePath() -> String {
        if let dir = bundledBinDir(),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("ffprobe").path) {
            return dir.appendingPathComponent("ffprobe").path
        }
        return "/opt/homebrew/bin/ffprobe"
    }

    public static func areBinariesPresent() -> Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath())
            && FileManager.default.isExecutableFile(atPath: ffprobePath())
    }
}