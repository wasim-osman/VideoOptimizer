// CRFLadder.swift - Resolution-dependent perceptual transparency CRF table (spec §2.3).

import Foundation

public enum ContentProfile: String, Sendable {
    case general
    case heavyGrain
    case animation
    case screenCapture
    case talkingHead
}

public enum EncoderKind: String, Sendable {
    case x265
    case x264
    case av1
    case videoToolbox
}

public struct CRFLadder: Sendable {
    public init() {}

    /// Base CRF per output height per encoder (spec §2.3 table).
    public func baseCRF(for height: Int, encoder: EncoderKind) -> Int {
        let h = max(height, 1)
        switch encoder {
        case .x264:
            if h <= 480 { return 17 }
            if h <= 720 { return 18 }
            if h <= 1080 { return 19 }
            if h <= 1440 { return 20 }
            if h <= 2160 { return 21 }
            return 22
        case .x265:
            if h <= 480 { return 19 }
            if h <= 720 { return 20 }
            if h <= 1080 { return 21 }
            if h <= 1440 { return 22 }
            if h <= 2160 { return 23 }
            return 25
        case .av1:
            if h <= 480 { return 26 }
            if h <= 720 { return 28 }
            if h <= 1080 { return 30 }
            if h <= 1440 { return 32 }
            if h <= 2160 { return 34 }
            return 36
        case .videoToolbox:
            return 65   // VideoToolbox -q:v scale, not CRF
        }
    }

    /// Content adjustments applied on top of the base ladder (spec §2.3 table).
    public func adjustedCRF(base: Int, profile: ContentProfile) -> Int {
        switch profile {
        case .heavyGrain:   return base + 2
        case .animation:    return base - 1
        case .screenCapture:return base - 2
        case .talkingHead:  return base + 1
        case .general:      return base
        }
    }

    /// Full ladder read: base + content adjustment + user quality offset, clamped to a sane CRF band.
    public func crf(for height: Int, profile: ContentProfile, encoder: EncoderKind, qualityOffset: Int) -> Int {
        let base = baseCRF(for: height, encoder: encoder)
        let adjusted = adjustedCRF(base: base, profile: profile)
        return min(max(adjusted + qualityOffset, 10), 40)
    }

    /// Real light-weight content classification using only probe data (spec §2.3 heuristics).
    /// Full detection (frame sampling, motion vectors) lives in VMAFSearch / v1.2.
    public func classify(_ media: MediaInfo) -> ContentProfile {
        let video = media.video
        guard video.width > 0 else { return .general }

        // Heavy grain: source BPP well above the codec's own norm.
        let norm: Double
        switch video.codecName.lowercased() {
        case "h264", "avc1", "avc3": norm = 0.08
        case "hevc", "h265", "hvc1", "hev1": norm = 0.05
        case "av1": norm = 0.04
        default: norm = 0.06
        }
        if media.bpp > norm * 2.0 {
            return .heavyGrain
        }
        return .general
    }
}