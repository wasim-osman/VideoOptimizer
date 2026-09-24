// VMAFSearch.swift - Netflix-style per-title CRF binary search scored by libvmaf (spec §2.5).

import Foundation

public struct VMAFSearch: Sendable {
    private let ffmpegPath: String

    public init(ffmpegPath: String = BinaryLocator.ffmpegPath()) {
        self.ffmpegPath = ffmpegPath
    }

    public struct Result: Sendable {
        public let bestCRF: Int
        public let harmonicMeanScores: [Double]
        public let segmentCount: Int
    }

    /// Tune the encoder's CRF by scoring a few 4s segments with libvmaf.
    /// Model selection: 4K model for sources ≥ 1440p, else default nflx_vmaf_v4a_v0_6_b16f-30.
    public func search(
        media: MediaInfo,
        plan: EncodePlan,
        baseCRF: Int,
        iterations: Int = 3
    ) async throws -> Result {
        let use4K = media.video.height >= 1440
        let model = use4K ? "model_path=/opt/homebrew/share/libvmaf/model/vmaf_4k_v0.6.1.json"
                          : "model_path=/opt/homebrew/share/libvmaf/model/vmaf_v0.6.1.json"

        // Extract 4 segments spread across the timeline, each ~4s.
        let duration = media.format.duration
        guard duration > 20 else {
            // Too short to sample — just return the base CRF untouched.
            return Result(bestCRF: baseCRF, harmonicMeanScores: [], segmentCount: 0)
        }
        let offsets: [Double] = [0.1, 0.35, 0.6, 0.85].map { $0 * duration }
        let segmentLength = 4.0

        var low = max(baseCRF - 8, 10)
        var high = min(baseCRF + 8, 40)
        var bestCRF = baseCRF
        var scores: [Double] = []

        for _ in 0..<iterations {
            let probe = (Double(low) + Double(high)) / 2
            let crf = Int(probe.rounded())
            do {
                let score = try await scoreCRF(
                    media: media,
                    crf: crf,
                    offsets: offsets,
                    segmentLength: segmentLength,
                    model: model
                )
                scores.append(score)
                if score >= 95 {
                    // Quality headroom: push smaller.
                    high = crf
                } else if score >= 92 {
                    bestCRF = crf
                    high = crf
                } else {
                    low = crf
                }
            } catch {
                break
            }
        }
        return Result(bestCRF: bestCRF, harmonicMeanScores: scores, segmentCount: offsets.count)
    }

    /// Encodes one segment at a given CRF and scores it against the source with libvmaf.
    private func scoreCRF(
        media: MediaInfo,
        crf: Int,
        offsets: [Double],
        segmentLength: Double,
        model: String
    ) async throws -> Double {
        var scores: [Double] = []
        for offset in offsets {
            // -ss before -i and -t limit the decode/encode window.
            let args = [
                "-v", "quiet",
                "-ss", String(format: "%.3f", offset),
                "-i", media.format.filename,
                "-t", String(format: "%.3f", segmentLength),
                "-c:v", "libx265", "-crf", String(crf), "-preset", "fast",
                "-pix_fmt", "yuv420p10le",
                "-an", "-sn",
                "-vf", "libvmaf=\(model)",
                "-f", "null", "-",
            ]
            let text = try await runFFmpeg(args: args)
            scores.append(parseVMAF(from: text))
        }
        guard !scores.isEmpty else { return 0 }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return max(min(mean, 100), 0)
    }

    private func parseVMAF(from stderr: String) -> Double {
        guard let range = stderr.range(of: "VMAF score: ") else { return 0 }
        let tail = stderr[range.upperBound...]
        let num = tail.prefix { $0.isNumber || $0 == "." }
        return Double(num) ?? 0
    }

    private func runFFmpeg(args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: out + err, encoding: .utf8) ?? ""
    }
}