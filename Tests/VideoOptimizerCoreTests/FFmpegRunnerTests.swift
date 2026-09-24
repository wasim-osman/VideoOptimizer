// FFmpegRunnerTests.swift - Process lifecycle, atomic .part output, post-flight guard (spec §4.2).
//
// These drive the real FFmpegRunner against a stub "ffmpeg" shell script, so they
// exercise the file handling without encoding anything.

import Foundation
import Testing
@testable import VideoOptimizerCore

// The stub is configured through the environment, so these must not interleave.
//
// The time limit is not cosmetic: FFmpegRunner installs `readabilityHandler`s that
// busy-spin on `availableData` once the pipe reaches EOF, and clears them only after
// the blocking `waitUntilExit()` in a detached Task returns. Run several encodes in
// one process and that starves the cooperative thread pool — the suite stops making
// progress instead of failing. The limit turns that hang into a reported failure.
@Suite("FFmpegRunner", .serialized, .timeLimit(.minutes(1)))
final class FFmpegRunnerTests {
    private let dir: URL
    private let stub: URL
    private let argvLog: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vo-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        stub = dir.appendingPathComponent("ffmpeg-stub")
        argvLog = dir.appendingPathComponent("argv.txt")

        // Writes VO_STUB_SIZE bytes to its last argument, logs its argv, and
        // exits with VO_STUB_EXIT.
        let script = """
        #!/bin/sh
        : > "$VO_STUB_ARGV"
        for a in "$@"; do printf '%s\\n' "$a" >> "$VO_STUB_ARGV"; done
        for last; do :; done
        dd if=/dev/zero of="$last" bs=1 count="${VO_STUB_SIZE:-1000}" 2>/dev/null
        exit "${VO_STUB_EXIT:-0}"
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        setenv("VO_STUB_ARGV", argvLog.path, 1)
        setenv("VO_STUB_SIZE", "1000", 1)
        setenv("VO_STUB_EXIT", "0", 1)
    }

    deinit {
        unsetenv("VO_STUB_ARGV"); unsetenv("VO_STUB_SIZE"); unsetenv("VO_STUB_EXIT")
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(output: URL, inputSize: Int64 = 100_000) async -> FFmpegResult {
        await FFmpegRunner(binaryPath: stub.path).run(
            arguments: ["-i", "input.mp4", output.path],
            outputURL: output,
            inputSize: inputSize,
            duration: 10
        )
    }

    private func recordedArguments() -> [String] {
        (try? String(contentsOf: argvLog, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    private func partExists(_ output: URL) -> Bool {
        FileManager.default.fileExists(atPath: output.path + ".part")
    }

    // MARK: - Happy path

    @Test("a successful run renames the .part file into place")
    func successRenamesPartFile() async {
        let output = dir.appendingPathComponent("out.mp4")
        let result = await run(output: output)

        #expect(result.success, "\(result.message)")
        #expect(result.outputURL?.path == output.path)
        #expect(FileManager.default.fileExists(atPath: output.path), "final file should exist")
        #expect(partExists(output) == false, "the .part file must not survive a successful run")
    }

    @Test("encoding writes to a .part file, not the final path")
    func encodesToPartFile() async {
        let output = dir.appendingPathComponent("out.mp4")
        _ = await run(output: output)
        #expect(recordedArguments().last == output.path + ".part",
                "ffmpeg must write to <output>.part so a crash never leaves a half file in place")
    }

    @Test("an explicit muxer is supplied because .part breaks extension detection")
    func explicitMuxerSupplied() async throws {
        let output = dir.appendingPathComponent("out.mkv")
        _ = await run(output: output)
        let args = recordedArguments()
        let index = try #require(args.firstIndex(of: "-f"), "a .part output needs an explicit -f muxer, got \(args)")
        #expect(args[index + 1] == "matroska")
    }

    // MARK: - Overwrite

    /// The default conflict policy is overwrite, so a second run must replace the
    /// first output rather than fail on the rename.
    @Test("overwriting an existing output succeeds")
    func overwriteSucceeds() async throws {
        let output = dir.appendingPathComponent("out.mp4")
        try Data(repeating: 0xAB, count: 4242).write(to: output)

        let result = await run(output: output)

        #expect(result.success, "overwrite must succeed: \(result.message)")
        #expect(partExists(output) == false, "a failed rename leaves an orphan .part behind")
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64
        #expect(size == 1000, "the old file should have been replaced by the new encode")
    }

    // MARK: - Post-flight bloat guard

    @Test("an output larger than the source is discarded")
    func bloatedOutputDiscarded() async {
        setenv("VO_STUB_SIZE", "5000", 1)
        let output = dir.appendingPathComponent("out.mp4")

        let result = await run(output: output, inputSize: 4000)

        #expect(result.success == false)
        #expect(result.discardedAsBlob)
        #expect(FileManager.default.fileExists(atPath: output.path) == false,
                "a bloated result must never reach the final path")
        #expect(partExists(output) == false)
    }

    @Test("a marginal saving is discarded")
    func marginalSavingDiscarded() async {
        setenv("VO_STUB_SIZE", "950", 1)
        let output = dir.appendingPathComponent("out.mp4")
        let result = await run(output: output, inputSize: 1000)
        #expect(result.discardedAsBlob, "a 5% saving is not worth a re-encode")
    }

    // MARK: - Failure handling

    @Test("a failed run reports failure and leaves no orphan files")
    func failureLeavesNoOrphans() async {
        setenv("VO_STUB_EXIT", "1", 1)
        let output = dir.appendingPathComponent("out.mp4")

        let result = await run(output: output)

        #expect(result.success == false)
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
        #expect(partExists(output) == false, "a failed encode must clean up its .part file")
    }

    @Test("a missing binary fails cleanly")
    func missingBinaryFailsCleanly() async {
        let output = dir.appendingPathComponent("out.mp4")
        let result = await FFmpegRunner(binaryPath: dir.appendingPathComponent("nope").path).run(
            arguments: ["-i", "in.mp4", output.path],
            outputURL: output, inputSize: 100, duration: 1
        )
        #expect(result.success == false)
        #expect(result.message.contains("ffmpeg"), "the error should name the missing binary")
    }

    // MARK: - Cancellation

    /// Cancel must stop a running encode, report it as cancelled rather than failed,
    /// and leave nothing behind. The stub ignores 'q' on stdin, so this also proves
    /// the escalation to a signal works.
    @Test("cancel stops a running encode and reports it as cancelled")
    func cancelStopsARunningEncode() async throws {
        // A stub that runs long enough to be cancelled mid-encode.
        // `exec` matters: the shell replaces itself with sleep, so the process the
        // runner signals IS the long-running one. Without it the shell would sit in
        // wait() and neither SIGINT nor SIGKILL would reach the real worker — real
        // ffmpeg is a direct child, so the stub has to model that.
        let slowStub = dir.appendingPathComponent("ffmpeg-slow")
        try """
        #!/bin/sh
        for last; do :; done
        dd if=/dev/zero of="$last" bs=1 count=500 2>/dev/null
        exec sleep 20
        """.write(to: slowStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowStub.path)

        let output = dir.appendingPathComponent("out.mp4")
        let runner = FFmpegRunner(binaryPath: slowStub.path)

        async let result = runner.run(
            arguments: ["-i", "in.mp4", output.path],
            outputURL: output, inputSize: 100_000, duration: 30
        )

        // Give the process time to start and write its partial file.
        try await Task.sleep(for: .milliseconds(600))
        #expect(runner.isRunning, "precondition: the encode should be under way")
        runner.cancel()

        let finished = await result
        #expect(finished.cancelled, "a cancelled encode must not be reported as a plain failure")
        #expect(finished.success == false)
        #expect(partExists(output) == false, "cancelling must not leave a partial file behind")
        #expect(FileManager.default.fileExists(atPath: output.path) == false,
                "a cancelled encode must not produce a final file")
    }

    @Test("reusing a runner does not strand a continuation")
    func runnerCanBeReused() async {
        let runner = FFmpegRunner(binaryPath: stub.path)
        let first = dir.appendingPathComponent("a.mp4")
        let second = dir.appendingPathComponent("b.mp4")

        let r1 = await runner.run(arguments: ["-i", "in", first.path],
                                  outputURL: first, inputSize: 100_000, duration: 1)
        let r2 = await runner.run(arguments: ["-i", "in", second.path],
                                  outputURL: second, inputSize: 100_000, duration: 1)
        #expect(r1.success && r2.success)
    }
}
