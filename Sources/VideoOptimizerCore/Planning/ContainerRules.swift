// ContainerRules.swift - Output extension + container-compatibility decisions (spec §3.3).

import Foundation

public struct ContainerDecision: Sendable, Equatable {
    public var outputExtension: String
    public var changed: Bool
}

public struct ContainerRules: Sendable {
    public init() {}

    public func outputExtension(sourceURL: URL, media: MediaInfo) -> String {
        let sourceExt = sourceURL.pathExtension.lowercased()
        let base: String

        switch sourceExt {
        case "mp4", "m4v":
            base = "mp4"
        case "mov":
            base = "mov"
        case "mkv":
            base = "mkv"
        case "webm":
            // Keep webm only for VP9/AV1 + Opus; else fall back to mkv.
            let vp9orAv1 = ["vp9", "vp09", "av1"].contains(media.video.codecName.lowercased())
            let opusAudio = media.audios.isEmpty || media.audios.contains { $0.codecName.lowercased() == "opus" }
            base = (vp9orAv1 && opusAudio) ? "webm" : "mkv"
        case "avi", "wmv", "flv", "mpg", "mpeg", "ts", "vob":
            base = "mp4"
        default:
            base = "mp4"
        }

        // Override to MKV whenever MP4 cannot carry the streams.
        if media.containsPGSOrVobSub || media.containsTrueHD {
            return "mkv"
        }
        return base
    }

    public func decision(sourceURL: URL, media: MediaInfo) -> ContainerDecision {
        let outExt = outputExtension(sourceURL: sourceURL, media: media)
        return ContainerDecision(outputExtension: outExt, changed: outExt != sourceURL.pathExtension.lowercased())
    }

    /// Subtitle codec for the chosen container: MOV_TEXT in MP4/MOV, else keep/copy via MKV.
    public func subtitleCodec(for extensionName: String, sourceCodec: String) -> String {
        let ext = extensionName.lowercased()
        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            let s = sourceCodec.lowercased()
            switch s {
            case "mov_text", "subrip", "srt", "text": return "mov_text"
            case "ass", "ssa": return "mov_text"
            default: return "mov_text"   // MP4 can only hold mov_text in practice
            }
        }
        // MKV can hold most subtitle codecs; copy them (or transcode SRT→srt stays as copy).
        switch sourceCodec.lowercased() {
        case "subrip", "srt", "ass", "ssa", "pgs", "hdmv_pgs_subtitle", "dvd_subtitle":
            return "copy"
        default:
            return "srt"
        }
    }
}