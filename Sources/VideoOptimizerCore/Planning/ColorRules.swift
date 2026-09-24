// ColorRules.swift - Explicit colour tags + HDR10 metadata (spec §3.1).

import Foundation

public struct ColorRules: Sendable {
    public init() {}

    /// Build output colour-tag arguments copied verbatim from the probe.
    /// Dropping these is how videos come out washed out or oversaturated.
    public func colorArguments(from media: MediaInfo) -> [String] {
        var args: [String] = []
        let v = media.video
        if !v.colorPrimaries.isEmpty {
            args += ["-color_primaries", v.colorPrimaries]
        }
        if !v.colorTransfer.isEmpty {
            args += ["-color_trc", v.colorTransfer]
        }
        if !v.colorSpace.isEmpty {
            args += ["-colorspace", v.colorSpace]
        }
        if !v.colorRange.isEmpty {
            args += ["-color_range", v.colorRange]
        }
        return args
    }

    /// HDR10 parameters for x265-style encoders, built from probe side data (spec §3.1).
    /// Returns nil unless BOTH mastering-display and content-light metadata are actually present.
    /// HLG (arib-std-b67) and SDR content must NOT get master-display params — those belong to HDR10 (PQ/smpte2084).
    public func hdr10X265Params(from media: MediaInfo) -> String? {
        guard media.video.isHDR,
              media.video.hasMasteringDisplay,
              media.video.hasContentLight else {
            return nil
        }
        return "hdr10=1:master-display=\(media.video.masteringDisplay):max-cll=\(media.video.maxCLL)"
    }

    public func svtav1HDRParams(from media: MediaInfo) -> [String]? {
        guard media.video.isHDR else { return nil }
        var params: [String] = []
        if media.video.hasMasteringDisplay {
            params.append("mastering-display=\(media.video.masteringDisplay)")
        }
        if media.video.hasContentLight {
            params.append("content-light=\(media.video.maxCLL)")
        }
        params.append("enable-hdr=1")
        return ["-svtav1-params", params.joined(separator: ":")]
    }
}