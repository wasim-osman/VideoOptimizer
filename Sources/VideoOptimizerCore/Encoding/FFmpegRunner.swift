// FFmpegRunner.swift - Process lifecycle, cancellation, atomic .part output (spec §4.2).

import Foundation

public struct FFmpegResult: Sendable, Equatable {
    public var success: Bool
    public var outputURL: URL?
    public var discardedAsBlob: Bool
    public var message: String
    public var cancelled: Bool
}

public final class FFmpegRunner: @unchecked Sendable {
    public let binaryPath: String
    private var process: Process?
    private var stdinPipe: Pipe?
    /// Set by `cancel()`. ffmpeg exits 255 after handling its own SIGINT, so this
    /// flag is the only reliable way to tell a cancellation from a real failure.
    private var cancelRequested = false

    public init(binaryPath: String = BinaryLocator.ffmpegPath()) {
        self.binaryPath = binaryPath
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Runs `arguments` against `outputURL`. Writes to `<output>.part` and renames on success (spec §4.2).
    /// After finish, applies the post-flight bloat guard (spec §2.2).
    public func run(
        arguments: [String],
        outputURL: URL,
        inputSize: Int64,
        duration: Double,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> FFmpegResult {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return FFmpegResult(
                success: false, outputURL: nil, discardedAsBlob: false,
                message: "ffmpeg not executable at \(binaryPath)", cancelled: false
            )
        }

        let partPath = outputURL.path + ".part"
        var finalArgs = arguments
        // The .part suffix breaks ffmpeg's muxer self-detection — emit an explicit -f container.
        let muxer = muxerName(for: outputURL.pathExtension)
        if let muxer {
            // Insert "-f muxer" immediately before the output path.
            finalArgs.insert(contentsOf: ["-f", muxer], at: finalArgs.count - 1)
        }
        finalArgs[finalArgs.count - 1] = partPath

        let run = { [self] in
            await withTaskCancellationHandler {
                await execute(args: finalArgs, duration: duration, onProgress: onProgress)
            } onCancel: {
                self.cancel()
            }
        }

        let result: FFmpegResult
        if Task.isCancelled {
            cancel()
            result = FFmpegResult(
                success: false, outputURL: nil, discardedAsBlob: false,
                message: "Cancelled before start", cancelled: true
            )
        } else {
            result = await run()
        }

        switch result {
        case let r where !r.success:
            // A failed or cancelled run must not leave a half-written file beside the source.
            try? FileManager.default.removeItem(atPath: partPath)
            return r
        default:
            break
        }

        // Success: post-flight bloat guard.
        let exists = FileManager.default.fileExists(atPath: partPath)
        guard exists else {
            return FFmpegResult(
                success: false, outputURL: nil, discardedAsBlob: false,
                message: "ffmpeg finished but produced no output file", cancelled: false
            )
        }
        let outputSize = ((try? FileManager.default.attributesOfItem(atPath: partPath)[.size]) as? Int64) ?? 0
        if BloatGuard.postFlightShouldDiscard(inputSize: inputSize, outputSize: outputSize) {
            try? FileManager.default.removeItem(atPath: partPath)
            return FFmpegResult(
                success: false, outputURL: nil, discardedAsBlob: true,
                message: "Output was ≥92% of the input — the source was already efficient. Nothing written.",
                cancelled: false
            )
        }

        do {
            try promote(partPath: partPath, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(atPath: partPath)
            return FFmpegResult(
                success: false, outputURL: nil, discardedAsBlob: false,
                message: "Encode succeeded but the output could not be written to "
                    + "\(outputURL.path): \(error.localizedDescription)",
                cancelled: false
            )
        }
        return FFmpegResult(
            success: true, outputURL: outputURL, discardedAsBlob: false, message: "", cancelled: false
        )
    }

    /// Moves the finished `.part` file onto the final path.
    ///
    /// `moveItem` refuses to clobber an existing file, which is exactly what the
    /// default overwrite policy asks for — so replace in place when something is
    /// already there, and only fall back to a plain move for a fresh path.
    private func promote(partPath: String, to outputURL: URL) throws {
        let partURL = URL(fileURLWithPath: partPath)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            try FileManager.default.moveItem(at: partURL, to: outputURL)
            return
        }
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: partURL)
    }

    private func execute(
        args: [String],
        duration: Double,
        onProgress: (@Sendable (Double) -> Void)?
    ) async -> FFmpegResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let input = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = args
            process.standardInput = input
            process.standardOutput = stdout
            process.standardError = stderr
            // .utility, not .userInitiated: this can run for hours on a large source
            // (Apple's own guidance for a long-running, progress-visible task), and
            // letting it compete for scheduling at interactive priority is how a heavy
            // encode ends up starving the app's own UI thread — the Stop button and
            // the queue display go sluggish exactly when they matter most.
            process.qualityOfService = .utility
            self.process = process
            self.stdinPipe = input

            // Lock-boxed mutable state for the two readability handlers (Swift 6 concurrency).
            let state = Box()

            // Empty data means the pipe reached EOF. The handler keeps firing until it
            // is cleared, so clear it here — leaving it installed spins a dispatch
            // thread flat out for the rest of the process's life.
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                state.lockSync()
                for line in text.split(separator: "\n") {
                    state.parser.feed(line: String(line))
                }
                let percent = state.parser.latest.percent(duration: duration)
                state.unlockSync()
                onProgress?(percent)
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.split(separator: "\n").map(String.init)
                state.lockSync()
                state.buffer.append(contentsOf: lines)
                if state.buffer.count > 50 { state.buffer.removeFirst(state.buffer.count - 50) }
                state.unlockSync()
            }

            // Foundation's `waitUntilExit()` blocks a thread for the whole encode and
            // has been observed to hang even after the child is gone. terminationHandler
            // is called once, off-thread, and cannot miss the exit.
            process.terminationHandler = { [self] finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                // ffmpeg exits 255 after a SIGINT it handled itself, so the exit
                // status alone cannot distinguish "cancelled" from "failed".
                let cancelled = self.cancelRequested
                    || finished.terminationReason == .uncaughtSignal

                // Only clear the shared state if it still refers to this run.
                if self.process === finished {
                    self.process = nil
                    self.stdinPipe = nil
                }

                if finished.terminationStatus == 0 && !cancelled {
                    continuation.resume(returning: FFmpegResult(
                        success: true, outputURL: nil, discardedAsBlob: false, message: "", cancelled: false
                    ))
                } else {
                    let message = state.collectBuffer().joined(separator: "\n")
                    continuation.resume(returning: FFmpegResult(
                        success: false, outputURL: nil, discardedAsBlob: false,
                        message: message.isEmpty
                            ? "ffmpeg exited with status \(finished.terminationStatus)"
                            : message,
                        cancelled: cancelled
                    ))
                }
            }

            do {
                try process.run()
                // A cancel that arrived while the process was starting would otherwise
                // be dropped, leaving the encode to run to completion.
                if self.cancelRequested { self.escalate() }
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: FFmpegResult(
                    success: false, outputURL: nil, discardedAsBlob: false,
                    message: "Failed to launch ffmpeg: \(error.localizedDescription)", cancelled: false
                ))
            }
        }
    }

    private func muxerName(for ext: String) -> String? {
        switch ext.lowercased() {
        case "mp4", "m4v": return "mp4"
        case "mov": return "mov"
        case "mkv": return "matroska"
        case "webm": return "webm"
        case "avi": return "avi"
        case "ts": return "mpegts"
        case "flv": return "flv"
        default: return nil
        }
    }

    /// Thread-safe box for the parser + stderr ring buffer.
    private final class Box: @unchecked Sendable {
        private let mutex = NSLock()
        var parser = ProgressParser()
        var buffer: [String] = []

        func lockSync() { mutex.lock() }
        func unlockSync() { mutex.unlock() }
        func collectBuffer() -> [String] {
            mutex.lock()
            defer { mutex.unlock() }
            return buffer
        }
    }

    /// Graceful: 'q' on stdin makes ffmpeg finalise the file it is writing.
    /// Escalates to SIGINT after 3s, then SIGKILL after 2 more (spec §4.2).
    ///
    /// The 'q' only works because the command omits `-nostdin`; with that flag
    /// ffmpeg detaches from stdin and the write is silently ignored.
    public func cancel() {
        cancelRequested = true
        escalate()
    }

    /// Asks the process to stop, then insists.
    ///
    /// A cancel can arrive before the process has been launched. Dropping it in that
    /// case would strand the encode, so `execute` re-runs this once the process exists
    /// and `cancelRequested` is already set.
    private func escalate() {
        guard let process, process.isRunning else { return }

        if let input = stdinPipe {
            try? input.fileHandleForWriting.write(contentsOf: Data("q".utf8))
            try? input.fileHandleForWriting.close()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let p = self.process, p.isRunning else { return }
            p.interrupt()   // SIGINT — ffmpeg's own handler still tidies up
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let p = self.process, p.isRunning else { return }
                kill(p.processIdentifier, SIGKILL)   // last resort
            }
        }
    }
}