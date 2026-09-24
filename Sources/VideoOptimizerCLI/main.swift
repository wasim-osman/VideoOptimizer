import VideoOptimizerCore
import Foundation

// VideoOptimizer CLI — exercises the whole headless core against files or golden JSON.
//   usage: videooptimizercli <video-file> [mode] [--hardware|--software] [--encode]
//   mode:  fast | balanced | smallest

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: VideoOptimizerCLI <video-file> [fast|balanced|smallest] [--encode]")
    exit(2)
}
let file = args[1]
let mode: EncoderMode = args.count > 2 ? EncoderMode(rawValue: args[2]) ?? .balanced : .balanced

print("=== VideoOptimizer CLI (headless core test) ===")
print("Input: \(file)")

guard FileManager.default.fileExists(atPath: file) else {
    print("ERROR: input file does not exist: \(file)")
    print("Provide a real video path as argument 1 (e.g. videooptimizercli ~/Movies/clip.mp4)")
    exit(1)
}

// 1) Probe
let probe = FFProbeService()
let media: MediaInfo
do {
    media = try await probe.probe(url: URL(fileURLWithPath: file))
} catch {
    print("PROBE FAILED: \(error.localizedDescription)")
    exit(1)
}
print("Probe: \(media.video.width)x\(media.video.height) \(formatFPS(media.video.fps))fps")
print("  codec: \(media.video.codecName)  bpp: \(String(format: "%.4f", media.bpp))")
print("  audio tracks: \(media.audios.count)  subtitles: \(media.subtitles.count)")
print("  colour: \(media.video.colorSpace) / \(media.video.colorTransfer)  HDR: \(media.video.isHDR)")
print("  interlaced: \(media.video.fieldOrder)  rotation: \(media.video.rotation)°")

// 2) Bloat guard pre-flight
let bloat = BloatGuard()
switch bloat.preflight(media) {
case .alreadyOptimised(let reason):
    print("\nBLOAT GUARD: \(reason)")
    exit(0)
case .proceed:
    print("\nBloat guard: proceed (bpp above floor)")
}

// 3) Plan
var settings = Settings()
settings.encoderMode = mode
if args.contains("--hardware") { settings.useHardwareEncoder = true }
if args.contains("--software") { settings.useHardwareEncoder = false }
let plan = EncodePlanner().plan(media: media, settings: settings)

switch plan.outcome {
case .alreadyOptimized(let reason):
    print("ALREADY OPTIMIZED: \(reason)")
    exit(0)
default:
    break
}

print("Plan: \(plan.encoderUsed) CRF \(plan.crfUsed) → \(plan.outputURL.lastPathComponent)")
if plan.containerChanged {
    print("  container changed: .\(URL(fileURLWithPath: media.format.filename).pathExtension) → .\(plan.outputURL.pathExtension)")
}
print("  note: \(plan.estimatedQualityNote)")
print("\nArguments:")
print("  ffmpeg " + plan.arguments.joined(separator: " "))

// 4) Encoder capabilities
let caps = await EncoderCapabilities()
print("\nEncoders: x265:\(caps.hasX265) x264:\(caps.hasX264) svtav1:\(caps.hasSVT) hevc_vt:\(caps.hasHEVCVideoToolbox) av1_vt:\(caps.hasAV1VideoToolbox)")

// 5) Actual encode (small file only — skip large archival encodes via flag)
if args.contains("--encode") {
    print("\nEncoding…")
    let runner = FFmpegRunner()
    let result = await runner.run(
        arguments: plan.arguments,
        outputURL: plan.outputURL,
        inputSize: media.format.size,
        duration: media.format.duration
    ) { pct in
        if pct.truncatingRemainder(dividingBy: 0.1) < 0.001 {
            print("  \(Int(pct * 100))%", terminator: "\r")
        }
    }
    print("")
    switch result {
    case let r where r.discardedAsBlob:
        print("DISCARDED (post-flight bloat guard): \(r.message)")
    case let r where r.success:
        let outSize = (try? FileManager.default.attributesOfItem(atPath: r.outputURL!.path)[.size] as? Int64) ?? 0
        let inSize = media.format.size
        let pct = inSize > 0 ? (1 - Double(outSize) / Double(inSize)) * 100 : 0
        print("SUCCESS: \(formatBytes(outSize)) vs \(formatBytes(inSize)) → \(String(format: "%.1f%%", pct)) smaller")
        print("  → \(r.outputURL!.path)")
    default:
        print("FAILED: \(result.message)")
    }
} else {
    print("\n(Add --encode to run the actual encode.)")
}

func formatFPS(_ fps: Double) -> String {
    String(format: "%.2f", fps)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}