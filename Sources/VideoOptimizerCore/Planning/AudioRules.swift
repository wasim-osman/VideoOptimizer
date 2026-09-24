// AudioRules.swift - Per-track copy-or-transcode decisions (spec §3.2).

import Foundation

public enum AudioAction: Sendable, Equatable {
    case copy
    case transcode(codec: String, bitrate: Int)
}

public struct AudioRules: Sendable {
    /// Above this many bits per second per channel, an already-lossy track is
    /// carrying more data than it needs (spec §3.2).
    static let perChannelCeiling: Double = 128_000

    public init() {}

    /// Spec §3.2:
    ///   copy  if codec in {aac, opus, ac3, eac3} and bitrate_per_channel < 128k
    ///   transcode to AAC 192k stereo / 384k 5.1 (Opus if mkv) for lossless/large codecs
    ///   else copy
    public func action(for stream: MediaInfo.Audio, outputContainerIsMKV: Bool) -> AudioAction {
        let codec = stream.codecName.lowercased()
        let bitratePerChannel: Double = stream.channels > 0 && stream.bitrate > 0
            ? Double(stream.bitrate) / Double(stream.channels)
            : 0

        switch codec {
        case "aac", "opus", "ac3", "eac3":
            // An unknown bitrate is not evidence of waste — copy rather than guess,
            // since a needless lossy-to-lossy transcode costs a generation of quality.
            if bitratePerChannel == 0 || bitratePerChannel < Self.perChannelCeiling {
                return .copy
            }
            // Well above the ceiling (e.g. 640k AC-3 on stereo) there is real waste to
            // reclaim, and the saving outweighs the second generation of loss.
            let bitrate = stream.channels >= 6 ? 384_000 : 192_000
            return .transcode(codec: outputContainerIsMKV ? "libopus" : "aac", bitrate: bitrate)
        case "pcm", "pcm_s16le", "pcm_s24le", "pcm_s32le", "flac", "alac", "truehd", "dts", "dts_hd", "dtshd":
            let bitrate = stream.channels >= 6 ? 384_000 : 192_000
            let codec = outputContainerIsMKV ? "libopus" : "aac"
            return .transcode(codec: codec, bitrate: bitrate)
        default:
            return .copy
        }
    }
}