// FFProbeService.swift - Runs ffprobe and decodes the JSON into MediaInfo (spec §2.1).

import Foundation

public enum ProbeError: LocalizedError, Sendable {
    case binaryMissing(String)
    case probeFailed(String)
    case noVideoStream

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let p): return "ffprobe not found at \(p)"
        case .probeFailed(let m): return "ffprobe failed: \(m)"
        case .noVideoStream: return "No video stream found in input"
        }
    }
}

public struct FFProbeService: Sendable {
    public init() {}

    public func probe(url: URL, binPath: String = BinaryLocator.ffprobePath()) async throws -> MediaInfo {
        guard FileManager.default.isExecutableFile(atPath: binPath) else {
            throw ProbeError.binaryMissing(binPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams", "-show_format", "-show_chapters",
            url.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outputHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        try process.run()

        let outData = outputHandle.readDataToEndOfFile()
        let errData = stderrHandle.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw ProbeError.probeFailed(message)
        }

        let decoder = JSONDecoder()
        do {
            let raw = try decoder.decode(FFProbeJSON.self, from: outData)
            return try raw.toMediaInfo()
        } catch {
            throw ProbeError.probeFailed(error.localizedDescription)
        }
    }

    // MARK: - JSON shapes mirroring `ffprobe -show_streams -show_format -show_chapters`

    public struct FFProbeJSON: Decodable {
        public let streams: [Stream]?
        public let format: FormatNode?
        public let chapters: [ChapterNode]?
    }

    public struct Stream: Decodable {
        public let index: Int?
        public let codec_type: String?
        public let codec_name: String?
        public let width: Int?
        public let height: Int?
        public let pix_fmt: String?
        public let avg_frame_rate: String?
        public let r_frame_rate: String?
        public let bit_rate: String?
        public let color_primaries: String?
        public let color_transfer: String?
        public let color_space: String?
        public let color_range: String?
        public let field_order: String?
        public let sample_rate: String?
        public let channels: Int?
        public let channel_layout: String?
        public let disposition: DispositionNode?
        public let duration: String?
        public let side_data_list: [SideDataNode]?
        public let tags: [String: String]?
    }

    public struct DispositionNode: Decodable {
        public let isDefault: Int?
        public let forced: Int?
        public let original: Int?

        enum CodingKeys: String, CodingKey {
            case isDefault = "default"
            case forced, original
        }
    }

    public struct SideDataNode: Decodable {
        public let type: String?
        public let rotation: Int?
        public let displaymatrix: String?
        public let mastering_display_metadata: MasteringNode?
        public let max_content_light_level: Int?
        public let max_frame_average_light_level: Int?
    }

    public struct MasteringNode: Decodable {
        // ffprobe emits an array of "[r,g,b]" primaries, white point, and max/min luminance.
        public let primaries: String?
        public let white_point: String?
        public let luminance: String?
    }

    public struct FormatNode: Decodable {
        public let filename: String?
        public let format_name: String?
        public let duration: String?
        public let size: String?
        public let bit_rate: String?
        public let tags: [String: String]?
    }

    public struct ChapterNode: Decodable {}

    public func parse(_ raw: FFProbeJSON) throws -> MediaInfo {
        try raw.toMediaInfo()
    }
}

extension FFProbeService.FFProbeJSON {
    public func toMediaInfo() throws -> MediaInfo {
        var media = MediaInfo()
        guard let streams = streams else {
            throw ProbeError.probeFailed("ffprobe returned no streams key")
        }

        for stream in streams {
            guard let type = stream.codec_type else { continue }
            switch type {
            case "video":
                let v = stream
                media.video.codecName = v.codec_name ?? ""
                media.video.width = v.width ?? 0
                media.video.height = v.height ?? 0
                media.video.pixFmt = v.pix_fmt ?? ""
                media.video.bitrate = Int(v.bit_rate ?? "") ?? 0
                media.video.avgFrameRate = v.avg_frame_rate ?? ""
                media.video.rFrameRate = v.r_frame_rate ?? ""
                media.video.fps = parseFPS(v.avg_frame_rate)
                media.video.colorPrimaries = v.color_primaries ?? ""
                media.video.colorTransfer = v.color_transfer ?? ""
                media.video.colorSpace = v.color_space ?? ""
                media.video.colorRange = v.color_range ?? ""
                media.video.fieldOrder = v.field_order ?? "progressive"
                media.video.duration = Double(v.duration ?? "") ?? 0
                media.video.index = v.index ?? 0
                media.video.bitDepth = parseBitDepth(pixFmt: v.pix_fmt, transfer: v.color_transfer)
                media.video.isVariableFrameRate = (v.avg_frame_rate != v.r_frame_rate)
                media.video.sampleAspectRatio = "1:1"

                if let tags = v.tags, let rotate = tags["rotate"], let degree = Int(rotate) {
                    media.video.rotation = degree
                }
                if let sd = v.side_data_list {
                    for side in sd where side.type == "Display Matrix" {
                        if let r = side.rotation {
                            media.video.rotation = r
                        }
                    }
                    for side in sd where side.type == "Mastering display metadata" {
                        media.video.hasMasteringDisplay = true
                        if let m = side.mastering_display_metadata {
                            media.video.masteringDisplay = parseMastering(m, fallback: media)
                        }
                    }
                    for side in sd where side.type == "Content light level metadata" {
                        media.video.hasContentLight = true
                        let maxCLL = side.max_content_light_level ?? 0
                        let maxFALL = side.max_frame_average_light_level ?? 0
                        media.video.maxCLL = "\(maxCLL),\(maxFALL)"
                    }
                }
                let transfer = media.video.colorTransfer.lowercased()
                media.video.isHDR = ["smpte2084", "smpte2084_10", "arib-std-b67", "arib_std_b67", "pq", "hlg"]
                    .contains(transfer)
                    || media.video.hasMasteringDisplay
                    || media.video.hasContentLight

            case "audio":
                var a = MediaInfo.Audio()
                a.index = stream.index ?? 0
                a.codecName = stream.codec_name ?? ""
                a.sampleRate = Int(stream.sample_rate ?? "") ?? 0
                a.channels = stream.channels ?? 0
                a.channelLayout = stream.channel_layout ?? ""
                a.bitrate = Int(stream.bit_rate ?? "") ?? 0
                a.language = stream.tags?["language"] ?? ""
                a.isDefault = (stream.disposition?.isDefault ?? 0) == 1
                a.isForced = (stream.disposition?.forced ?? 0) == 1
                media.audios.append(a)

            case "subtitle":
                var s = MediaInfo.Subtitle()
                s.index = stream.index ?? 0
                s.codecName = stream.codec_name ?? ""
                s.language = stream.tags?["language"] ?? ""
                s.isDefault = (stream.disposition?.isDefault ?? 0) == 1
                s.isForced = (stream.disposition?.forced ?? 0) == 1
                media.subtitles.append(s)

            default:
                break
            }
        }

        if let f = format {
            media.format.filename = f.filename ?? ""
            media.format.formatName = f.format_name ?? ""
            media.format.duration = Double(f.duration ?? "") ?? 0
            media.format.size = Int64(f.size ?? "") ?? 0
            media.format.bitrate = Int(f.bit_rate ?? "") ?? 0
            media.format.tags = f.tags ?? [:]
            media.format.hasChapters = chapters?.isEmpty == false
        }

        // Stream-level bit_rate is often absent (e.g. VP9 in WebM, this 8.1.x build).
        // Fall back to the format bitrate, then to size/duration before giving up.
        if media.video.bitrate == 0 {
            if media.format.bitrate > 0 {
                media.video.bitrate = media.format.bitrate
            } else if media.format.duration > 0, media.format.size > 0 {
                media.video.bitrate = Int(Double(media.format.size * 8) / media.format.duration)
            }
        }

        guard media.hasVideo else { throw ProbeError.noVideoStream }
        return media
    }
}

func parseFPS(_ value: String?) -> Double {
    guard let value, value.contains("/") else { return Double(value ?? "") ?? 0 }
    let parts = value.split(separator: "/")
    guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 else { return 0 }
    return num / den
}

func parseBitDepth(pixFmt: String?, transfer: String?) -> Int {
    // Infer bit depth from pix_fmt name: yuv420p10le/p010/… → 10, else 8 (or 12).
    let lower = (pixFmt ?? "").lowercased()
    if lower.contains("12") { return 12 }
    if lower.contains("10") { return 10 }
    if transfer?.lowercased() == "smpte2084" { return 10 }
    return 8
}

func parseMastering(_ node: FFProbeService.MasteringNode, fallback: MediaInfo) -> String {
    // Format: G(0.0,0.0)B(0,0)R(0,0)WP(0,0)L(0,0)
    // ffprobe strings look like "0.678,0.050,0.678,0.050,0.480,0.060"?
    // We rebuild from the array if present; otherwise a safe BT.2020 default.
    let fallbackVal = "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
    guard let primaries = node.primaries?.split(separator: ",").compactMap({ Float($0) }),
          primaries.count >= 6,
          let white = node.white_point?.split(separator: ",").compactMap({ Float($0) }),
          white.count >= 2 else {
        return fallbackVal
    }
    // Convert x,y (0..1) to ffmpeg's G/B/R indices.
    func lu(_ x: Float) -> Int { Int(x * 50_000) }
    let gx = lu(primaries[0]), gy = lu(primaries[1])
    let bx = lu(primaries[2]), by = lu(primaries[3])
    let rx = lu(primaries[4]), ry = lu(primaries[5])
    let wx = lu(white[0]), wy = lu(white[1])
    let maxLum = Int((node.luminance?.split(separator: ",").compactMap(Float.init).first ?? 0) * 10_000)
    let minLum = Int((node.luminance?.split(separator: ",").compactMap(Float.init).last ?? 0.005) * 10_000)
    return "G(\(gx),\(gy))B(\(bx),\(by))R(\(rx),\(ry))WP(\(wx),\(wy))L(\(maxLum),\(minLum))"
}