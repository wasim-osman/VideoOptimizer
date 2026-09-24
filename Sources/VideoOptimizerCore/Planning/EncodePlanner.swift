// EncodePlanner.swift - Pure function: MediaInfo + Settings -> EncodePlan (spec §2, §3, §4.1).
// Core/Planning must have ZERO dependency on SwiftUI or Process.

import Foundation

public struct EncodePlanner: Sendable {
    private let bloatGuard = BloatGuard()
    private let ladder = CRFLadder()
    private let colorRules = ColorRules()
    private let audioRules = AudioRules()
    private let containerRules = ContainerRules()

    public init() {}

    public func plan(media: MediaInfo, settings: Settings) -> EncodePlan {
        // ------------------------------------------------------------------
        // 0. Pre-flight bloat guard (spec §2.2)
        // ------------------------------------------------------------------
        switch bloatGuard.preflight(media) {
        case .alreadyOptimised(let reason):
            return EncodePlan(
                arguments: [],
                inputURL: URL(fileURLWithPath: media.format.filename),
                outputURL: URL(fileURLWithPath: media.format.filename),
                outcome: .alreadyOptimized(reason: reason)
            )
        case .proceed:
            break
        }

        // ------------------------------------------------------------------
        // 1. Container decision
        // ------------------------------------------------------------------
        let inputURL = URL(fileURLWithPath: media.format.filename)
        let container = containerRules.decision(sourceURL: inputURL, media: media)
        let outputURL = PathSupport.outputURL(
            inputURL: inputURL,
            suffix: settings.suffix,
            outputExtension: container.outputExtension,
            outputLocation: settings.outputLocation,
            chosenFolderPath: settings.chosenFolderPath,
            conflictPolicy: settings.conflictPolicy
        )
        // If output already exists and policy is skip, bail early.
        // The output resolution has no bearing on conflict handling.
        if settings.conflictPolicy == .skip,
           FileManager.default.fileExists(atPath: outputURL.path) {
            return EncodePlan(
                arguments: [],
                inputURL: inputURL,
                outputURL: outputURL,
                outcome: .alreadyOptimized(reason: "Output already exists, skip policy — \(outputURL.lastPathComponent)")
            )
        }

        // ------------------------------------------------------------------
        // 2. Filters (decided first: they determine how frames must be decoded)
        // ------------------------------------------------------------------
        let profile = ladder.classify(media)
        let encoderMode = settings.encoderMode
        let codecChoice = settings.codecChoice
        let targetHeight: Int? = settings.outputResolution.height

        var filters: [String] = []

        // Interlaced sources are deinterlaced ahead of anything else (spec §3.1).
        if media.video.fieldOrder != "progressive", !media.video.fieldOrder.isEmpty {
            let topFieldFirst = media.video.fieldOrder.contains("tt")
                || media.video.fieldOrder.contains("tff")
            filters.append(topFieldFirst ? "yadif=mode=1:parity=tff" : "yadif=mode=1:parity=bff")
        }

        if let scale = PathSupport.scaleFilter(
            mediaHeight: media.video.height,
            mediaWidth: media.video.width,
            requestedHeight: targetHeight
        ) {
            filters.append(scale)
        }

        let vfArgs: [String] = filters.isEmpty ? [] : ["-vf", filters.joined(separator: ",")]

        // yadif and zscale are software filters: they cannot read frames that are
        // still sitting in GPU memory, so their presence rules out a zero-copy decode.
        let needsSoftwareFrames = !filters.isEmpty

        // ------------------------------------------------------------------
        // 3. Codec / encoder + CRF ladder
        // ------------------------------------------------------------------
        let encoder: String
        let encoderKind: EncoderKind
        let crf: Int
        var presetArgs: [String] = []
        var x265Params: String? = nil   // single -x265-params string (merged tuning + HDR10)

        let wantsHardware = settings.useHardwareEncoder
        let ladderHeight = targetHeight ?? media.video.height

        switch encoderMode {
        case .fast:
            encoder = "hevc_videotoolbox"
            encoderKind = .videoToolbox
            crf = videoToolboxQuality(base: Self.fastQuality, offset: settings.qualityOffset)
            presetArgs = ["-realtime", "0"]

        case .balanced:
            // Use the Apple media engine when requested — far faster, slightly larger files.
            if wantsHardware {
                encoder = "hevc_videotoolbox"
                encoderKind = .videoToolbox
                crf = videoToolboxQuality(base: Self.balancedQuality, offset: settings.qualityOffset)
                presetArgs = ["-realtime", "0"]
            } else {
                (encoder, encoderKind) = Self.softwareEncoder(for: codecChoice, default: .x265)
                crf = ladder.crf(
                    for: ladderHeight,
                    profile: profile,
                    encoder: encoderKind,
                    qualityOffset: settings.qualityOffset
                )
                presetArgs = encoderKind == .av1
                    ? ["-preset", "6", "-threads", "0"]
                    : ["-preset", "medium", "-threads", "0"]
                if encoderKind == .x265 {
                    x265Params = "aq-mode=3:psy-rd=2.0:psy-rdoq=1.0:deblock=-1,-1:frame-threads=0"
                }
            }

        case .smallest:
            // AV1 unless the user pinned a different codec.
            (encoder, encoderKind) = Self.softwareEncoder(for: codecChoice, default: .av1)
            crf = ladder.crf(
                for: ladderHeight,
                profile: profile,
                encoder: encoderKind,
                qualityOffset: settings.qualityOffset
            )
            switch encoderKind {
            case .av1: presetArgs = ["-preset", "5", "-threads", "0"]
            default:   presetArgs = ["-preset", "slow", "-threads", "0"]
            }
            if encoderKind == .x265 {
                x265Params = "aq-mode=3:psy-rd=2.0:psy-rdoq=1.0:deblock=-1,-1:frame-threads=0"
            }
        }

        let hwAccelArgs = decodeHwaccelArgs(
            for: media,
            encoderIsHardware: encoderKind == .videoToolbox,
            needsSoftwareFrames: needsSoftwareFrames
        )


        // ------------------------------------------------------------------
        // 4. Assembling the argument array (spec §3 reference shape)
        // ------------------------------------------------------------------
        // Deliberately no `-nostdin`: FFmpegRunner cancels by writing 'q' to stdin so
        // ffmpeg finalises the partial file instead of being killed mid-write. The
        // runner owns the pipe and never sends anything else, so there is no risk of
        // ffmpeg consuming terminal input.
        var args: [String] = [
            "-hide_banner", "-y",
        ]
        // Hardware decode options must precede -i (ffmpeg input options).
        args += hwAccelArgs
        args += [
            "-i", inputURL.path,
            "-map", "0:v:0",
        ]

        if settings.keepAudio {
            for i in media.audios.indices {
                args += ["-map", "0:a:\(i)"]
            }
        }
        if settings.keepSubtitles, media.subtitles.count > 0 {
            for i in media.subtitles.indices {
                args += ["-map", "0:s:\(i)"]
            }
        }
        if settings.keepChapters {
            args += ["-map_chapters", "0"]
        }
        args += ["-map_metadata", "0"]

        // Video encoder.
        args += ["-c:v", encoder]
        switch encoderKind {
        case .videoToolbox:
            // VideoToolbox maps quality as a "quality" value (0 = best, 100 = worst), reversed vs CRF.
            args += ["-q:v", String(crf)]
        default:
            args += ["-crf", String(crf)]
        }
        args += presetArgs

        // Always encode 10-bit (spec §2.3) unless user disabled it.
        if settings.alwaysUse10Bit && encoderKind != .videoToolbox {
            args += ["-pix_fmt", "yuv420p10le"]
        }

        // HEVC in MP4/MOV must carry the hvc1 tag (spec §8.1 / §3.1).
        if encoder.contains("x265") || encoder.contains("h265") {
            args += ["-tag:v", "hvc1"]
        }
        if encoder.contains("hevc_videotoolbox") {
            args += ["-tag:v", "hvc1"]
        }

        // HDR10 metadata merged into the single -x265-params string (spec §3.1).
        // Never emit a second -x265-params — ffmpeg only honours the last one, dropping tuning.
        if encoderKind == .x265 {
            if let hdr = colorRules.hdr10X265Params(from: media) {
                x265Params = (x265Params.map { $0 + ":" } ?? "") + hdr
            }
        }
        if let params = x265Params {
            args += ["-x265-params", params]
        }
        if encoderKind == .av1 {
            if let hdr = colorRules.svtav1HDRParams(from: media) {
                args += hdr
            }
        }

        // Colour tags copied explicitly (spec §3.1).
        args += colorRules.colorArguments(from: media)

        // Audio: per-track copy-or-transcode.
        let mkvContainer = container.outputExtension.lowercased() == "mkv"
        for (i, stream) in media.audios.enumerated() {
            switch audioRules.action(for: stream, outputContainerIsMKV: mkvContainer) {
            case .copy:
                args += ["-c:a:\(i)", "copy"]
            case .transcode(let codec, let bitrate):
                args += ["-c:a:\(i)", codec, "-b:a:\(i)", String(bitrate)]
            }
        }
        // No audio tracks: silence is the default; nothing to do.

        // Subtitles: MP4 can only carry mov_text; MKV can copy most (spec §3.3).
        if settings.keepSubtitles, media.subtitles.count > 0 {
            for (i, stream) in media.subtitles.enumerated() {
                let subCodec = containerRules.subtitleCodec(for: container.outputExtension, sourceCodec: stream.codecName)
                args += ["-c:s:\(i)", subCodec]
            }
        }

        // VFR sources need passthrough to avoid audio drift (spec §8.3).
        // A deinterlace doubles the frame rate, so the two cannot both apply.
        if media.video.isVariableFrameRate, filters.allSatisfy({ !$0.hasPrefix("yadif") }) {
            args += ["-fps_mode", "passthrough"]
        }

        args += vfArgs

        // Container flags. -movflags is a MOV/MP4 muxer option; Matroska ignores it,
        // and +disable_chapters would contradict the -map_chapters above in any case.
        switch container.outputExtension.lowercased() {
        case "mp4", "mov", "m4v":
            args += ["-movflags", "+faststart+use_metadata_tags"]
        default:
            break
        }

        // Hard-away stdin + progress stream (spec §3, §3.4).
        args += ["-progress", "pipe:1", "-nostats", "-loglevel", "error"]

        // Custom power-user arguments appended last so they can override.
        if !settings.extraArguments.isEmpty {
            let extras = settings.extraArguments.split(whereSeparator: \.isWhitespace).map(String.init)
            args += extras
        }

        args += [outputURL.path]

        return EncodePlan(
            arguments: args,
            inputURL: inputURL,
            outputURL: outputURL,
            outcome: .planned,
            containerChanged: container.changed,
            crfUsed: crf,
            encoderUsed: encoder,
            estimatedQualityNote: "\(encoder) CRF-\(crf) @\(targetHeight ?? media.video.height)p (\(profile.rawValue))"
        )
    }

    /// VideoToolbox decode flags.
    ///
    /// Zero-copy (frames left in GPU memory) is only available when nothing downstream
    /// needs to read them on the CPU — that means a hardware encode and no software
    /// filters. Otherwise the frames must be downloaded, and the download format has to
    /// carry the source's bit depth: NV12 is 8-bit, so a 10-bit or HDR source needs P010
    /// or the extra depth is thrown away before the encoder ever sees it.
    private func decodeHwaccelArgs(
        for media: MediaInfo,
        encoderIsHardware: Bool,
        needsSoftwareFrames: Bool
    ) -> [String] {
        // Both download formats are 4:2:0. Asking the VideoToolbox decoder for one
        // from a 4:2:2 or 4:4:4 source fails the whole encode with "Unsupported or
        // mismatching pixel format" — so anything else decodes in software.
        guard Self.isChromaSubsampled420(media.video.pixFmt) else { return [] }

        let outputFormat: String
        if encoderIsHardware && !needsSoftwareFrames {
            outputFormat = "videotoolbox"
        } else {
            let isDeep = media.video.bitDepth > 8 || media.video.isHDR
            outputFormat = isDeep ? "p010" : "nv12"
        }
        return ["-hwaccel", "videotoolbox", "-hwaccel_output_format", outputFormat]
    }

    /// Whether ffprobe's `pix_fmt` names a 4:2:0 layout, the only chroma subsampling
    /// the nv12/p010 download formats can represent. An unknown format is treated as
    /// unsupported: falling back to software decode costs speed, guessing costs the encode.
    static func isChromaSubsampled420(_ pixFmt: String) -> Bool {
        let name = pixFmt.lowercased()
        guard !name.isEmpty else { return false }
        // Explicitly 4:2:2 / 4:4:4 / 4:1:1 and friends.
        if name.contains("422") || name.contains("444") || name.contains("411")
            || name.contains("440") || name.contains("gbr") {
            return false
        }
        return name.contains("420") || name == "nv12" || name.hasPrefix("p010")
    }

    // MARK: - Encoder selection

    /// VideoToolbox's `-q:v` is a 0…100 quality scale where HIGHER means better quality
    /// (confirmed empirically: q=65 yields a larger file than q=50). It is NOT a CRF,
    /// so the ladder's values and its 10…40 clamp do not apply here.
    static let fastQuality = 55
    static let balancedQuality = 70

    /// Applies the user's quality offset to a VideoToolbox quality value.
    /// The offset is expressed in CRF steps, where negative means better quality;
    /// on this inverted 0…100 scale that means moving up.
    private func videoToolboxQuality(base: Int, offset: Int) -> Int {
        min(max(base - offset * 5, 0), 100)
    }

    /// Maps the user's codec choice onto a software encoder, falling back to `default`
    /// when they have expressed no preference.
    static func softwareEncoder(
        for choice: CodecChoice,
        default fallback: EncoderKind
    ) -> (String, EncoderKind) {
        switch choice {
        case .h264: return ("libx264", .x264)
        case .hevc: return ("libx265", .x265)
        case .av1:  return ("libsvtav1", .av1)
        case .auto:
            switch fallback {
            case .x264:         return ("libx264", .x264)
            case .av1:          return ("libsvtav1", .av1)
            case .x265,
                 .videoToolbox: return ("libx265", .x265)
            }
        }
    }
}