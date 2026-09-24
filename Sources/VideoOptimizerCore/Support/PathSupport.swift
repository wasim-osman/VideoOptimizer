// PathSupport.swift - Path construction, filename sanitisation (spec §8.5), output resolution.

import Foundation

public enum PathSupport: Sendable {
    public static func sanitisedBaseName(_ fileName: String) -> String {
        // ":" is legal in Finder but becomes "/" at the POSIX layer (spec §8.5).
        var base = fileName.replacingOccurrences(of: ":", with: "_")
        // Also neutralise other path-breaking characters defensively.
        base = base.replacingOccurrences(of: "\0", with: "")
        if base.hasPrefix(".") {
            base = "_" + base
        }
        return base
    }

    /// Build the output URL honouring the naming spec `<name>_optimized.<ext>`.
    public static func outputURL(
        inputURL: URL,
        suffix: String,
        outputExtension: String,
        outputLocation: OutputLocation,
        chosenFolderPath: String,
        conflictPolicy: ResolveConflict
    ) -> URL {
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let safe = sanitisedBaseName(baseName)
        let targetDirectory: URL
        switch outputLocation {
        case .sameAsSource:
            targetDirectory = inputURL.deletingLastPathComponent()
        case .chooseFolder:
            targetDirectory = URL(fileURLWithPath: chosenFolderPath, isDirectory: true)
        case .askEachTime:
            targetDirectory = inputURL.deletingLastPathComponent()
        }

        var candidate = targetDirectory
            .appendingPathComponent(safe + suffix + "." + outputExtension)

        switch conflictPolicy {
        case .overwrite:
            return candidate
        case .numberIt:
            var counter = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = targetDirectory
                    .appendingPathComponent("\(safe)\(suffix) \(counter).\(outputExtension)")
                counter += 1
            }
            return candidate
        case .skip:
            return candidate
        }
    }

    /// Never upscale. Preserves aspect ratio via -2, which keeps the derived side even.
    ///
    /// A resolution label names the SHORT edge: 1920x1080 and 1080x1920 are both "1080p".
    /// Comparing against the long edge would treat 1280x720 as a 1280-tall source and
    /// happily "downscale" it to 1080 — an upscale. Comparing against height alone
    /// would rescale portrait video that is already at the requested resolution.
    public static func scaleFilter(mediaHeight: Int, mediaWidth: Int, requestedHeight: Int?) -> String? {
        guard let target = requestedHeight, mediaWidth > 0, mediaHeight > 0 else { return nil }
        let sourceResolution = min(mediaWidth, mediaHeight)
        guard target < sourceResolution else { return nil }

        // Scale the short edge to the target and let the long edge follow.
        //
        // `scale`, not `zscale`: zscale needs libzimg, which many ffmpeg builds omit
        // (Homebrew's does). Emitting it there fails the whole encode with
        // "Filter not found", so every downscale would break on a fallback binary.
        let dimensions = mediaHeight <= mediaWidth
            ? "-2:\(target)"      // landscape or square: short edge is the height
            : "\(target):-2"      // portrait: short edge is the width
        return "scale=\(dimensions):flags=lanczos"
    }
}