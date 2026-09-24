// PathSupportTests.swift - Output naming, conflict handling, never-upscale (spec §8.5).

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("PathSupport")
final class PathSupportTests {
    private let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vo-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Sanitisation

    @Test("a colon is neutralised because POSIX reads it as a path separator")
    func colonIsNeutralised() {
        // Finder shows "Movie: Part 2" but POSIX sees a "/" — it would write to a subdirectory.
        let safe = PathSupport.sanitisedBaseName("Movie: Part 2")
        #expect(safe.contains(":") == false)
        #expect(safe.contains("/") == false)
    }

    @Test("a leading dot is neutralised so the output is not hidden")
    func leadingDotIsNeutralised() {
        #expect(PathSupport.sanitisedBaseName(".hidden").hasPrefix(".") == false)
    }

    @Test("ordinary names are left alone")
    func ordinaryNamesUntouched() {
        #expect(PathSupport.sanitisedBaseName("A Film (2024) [1080p]") == "A Film (2024) [1080p]")
    }

    // MARK: - Naming

    @Test("the output sits beside the source with the suffix")
    func outputSitsBesideSource() {
        let out = PathSupport.outputURL(
            inputURL: dir.appendingPathComponent("clip.mov"), suffix: "_optimized",
            outputExtension: "mp4", outputLocation: .sameAsSource,
            chosenFolderPath: "", conflictPolicy: .overwrite
        )
        #expect(out.deletingLastPathComponent().path == dir.path)
        #expect(out.lastPathComponent == "clip_optimized.mp4")
    }

    @Test("a chosen folder is honoured")
    func chosenFolderHonoured() {
        let elsewhere = dir.appendingPathComponent("out")
        let out = PathSupport.outputURL(
            inputURL: dir.appendingPathComponent("clip.mp4"), suffix: "_optimized",
            outputExtension: "mp4", outputLocation: .chooseFolder,
            chosenFolderPath: elsewhere.path, conflictPolicy: .overwrite
        )
        #expect(out.deletingLastPathComponent().path == elsewhere.path)
    }

    // MARK: - Conflicts

    @Test("numberIt finds a free name")
    func numberItFindsFreeName() throws {
        try Data().write(to: dir.appendingPathComponent("clip_optimized.mp4"))
        let out = PathSupport.outputURL(
            inputURL: dir.appendingPathComponent("clip.mp4"), suffix: "_optimized",
            outputExtension: "mp4", outputLocation: .sameAsSource,
            chosenFolderPath: "", conflictPolicy: .numberIt
        )
        #expect(FileManager.default.fileExists(atPath: out.path) == false,
                "numberIt must return a name that is actually free")
    }

    @Test("numberIt keeps counting past several collisions")
    func numberItCountsPastCollisions() throws {
        try Data().write(to: dir.appendingPathComponent("clip_optimized.mp4"))
        try Data().write(to: dir.appendingPathComponent("clip_optimized 1.mp4"))
        try Data().write(to: dir.appendingPathComponent("clip_optimized 2.mp4"))

        let out = PathSupport.outputURL(
            inputURL: dir.appendingPathComponent("clip.mp4"), suffix: "_optimized",
            outputExtension: "mp4", outputLocation: .sameAsSource,
            chosenFolderPath: "", conflictPolicy: .numberIt
        )
        #expect(FileManager.default.fileExists(atPath: out.path) == false)
    }

    @Test("the output never collides with the source itself")
    func outputNeverCollidesWithSource() {
        // Source already carries the suffix — re-running must not target the input file.
        let source = dir.appendingPathComponent("clip_optimized.mp4")
        let out = PathSupport.outputURL(
            inputURL: source, suffix: "_optimized", outputExtension: "mp4",
            outputLocation: .sameAsSource, chosenFolderPath: "", conflictPolicy: .overwrite
        )
        #expect(out.path != source.path, "the plan would have ffmpeg read and write the same file")
    }

    // MARK: - Scaling

    @Test("a downscale is requested for a taller source")
    func downscaleRequested() throws {
        let filter = try #require(PathSupport.scaleFilter(mediaHeight: 2160, mediaWidth: 3840, requestedHeight: 1080))
        #expect(filter.contains("1080"))
        #expect(filter.hasPrefix("scale="))
    }

    /// zscale needs libzimg, which Homebrew's ffmpeg (and many other builds) omit.
    /// Emitting it there fails the encode outright with "Filter not found".
    @Test("the scale filter does not depend on an optional ffmpeg library")
    func scaleFilterUsesAlwaysAvailableFilter() throws {
        let filter = try #require(PathSupport.scaleFilter(mediaHeight: 2160, mediaWidth: 3840, requestedHeight: 720))
        #expect(filter.contains("zscale") == false, "zscale is not present in every ffmpeg build")
    }

    @Test("a portrait source scales on its width so the short edge hits the target")
    func portraitScalesOnWidth() throws {
        let filter = try #require(PathSupport.scaleFilter(mediaHeight: 3840, mediaWidth: 2160, requestedHeight: 1080))
        #expect(filter.contains("scale=1080:-2"), "got \(filter)")
    }

    @Test("no filter when the source resolution is requested")
    func noFilterForSourceResolution() {
        #expect(PathSupport.scaleFilter(mediaHeight: 1080, mediaWidth: 1920, requestedHeight: nil) == nil)
    }

    /// The comparison must be against the source HEIGHT. Measuring against the long
    /// edge lets any target below the width through — so ordinary 16:9 720p footage
    /// gets "downscaled" to 1080p, which is an upscale.
    @Test("an upscale is refused")
    func upscaleRefused() {
        #expect(PathSupport.scaleFilter(mediaHeight: 720, mediaWidth: 1280, requestedHeight: 1080) == nil,
                "a 720p source must never be scaled up to 1080p")
    }

    @Test("an upscale is refused at every rung above the source height",
          arguments: [1080, 1440, 2160])
    func upscaleRefusedAtEveryRung(target: Int) {
        #expect(PathSupport.scaleFilter(mediaHeight: 720, mediaWidth: 1280, requestedHeight: target) == nil,
                "720p must never be scaled up to \(target)p")
    }

    @Test("a portrait source is not rescaled by its long edge")
    func portraitNotRescaledByLongEdge() {
        // A 1080x1920 phone video is 1080p. Asking for 1080p must be a no-op,
        // not a scale driven by the 1920 long edge.
        let filter = PathSupport.scaleFilter(mediaHeight: 1920, mediaWidth: 1080, requestedHeight: 1080)
        #expect(filter == nil, "a portrait 1080p clip is already 1080p; got \(filter ?? "nil")")
    }
}
