// BloatGuard.swift - The two must-have defences against a *larger* output (spec §2.2).

import Foundation

public enum BloatGuardVerdict: Sendable, Equatable {
    case proceed
    case alreadyOptimised(reason: String)
}

public struct BloatGuard: Sendable {
    public init() {}

    /// BPP floor per source codec. Below this, re-encoding costs quality and saves nothing.
    public static func bppFloor(forCodec codecName: String) -> Double {
        switch codecName.lowercased() {
        case "h264", "avc1", "avc3", "x264": return 0.045
        case "hevc", "h265", "hvc1", "hev1", "vp9", "vp09": return 0.030
        case "av1": return 0.022
        default: return 0.030
        }
    }

    /// Pre-flight refusal: if the source BPP is already below the floor, skip (spec §2.2).
    public func preflight(_ media: MediaInfo) -> BloatGuardVerdict {
        guard media.hasVideo else { return .alreadyOptimised(reason: "No video stream found") }

        // A BPP of zero means ffprobe could not determine a bitrate at stream, format
        // or size/duration level — it does not mean the source is efficient. Refusing
        // here would silently reject every file with no duration metadata, so let it
        // through and rely on the post-flight size check instead.
        guard media.bpp > 0 else { return .proceed }

        let floor = Self.bppFloor(forCodec: media.video.codecName)
        guard media.bpp >= floor else {
            return .alreadyOptimised(
                reason: "Already optimised — \(format(media.bpp)) bits/pixel/frame is below the "
                    + "\(floor) floor for \(media.video.codecName). Re-encoding would only lose quality."
            )
        }
        return .proceed
    }

    /// Post-flight check: if output ≥ 92% of input size, discard it (spec §2.2).
    /// Returns true when the output should be discarded.
    public static func postFlightShouldDiscard(inputSize: Int64, outputSize: Int64) -> Bool {
        guard inputSize > 0 else { return false }
        return Double(outputSize) / Double(inputSize) >= 0.92
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}