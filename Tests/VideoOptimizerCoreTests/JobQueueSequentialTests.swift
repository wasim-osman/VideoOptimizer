// JobQueueSequentialTests.swift - Reproduces "drag a second file in after the first
// finishes" against the real pipeline (real ffprobe/ffmpeg, not a stub), since that
// orchestration lives above the parts the rest of the suite already covers in isolation.

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("JobQueue sequential drops", .serialized, .timeLimit(.minutes(3)))
final class JobQueueSequentialTests {
    private let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vo-jobqueue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A short, genuinely-bloated clip (real noise, not a flat testsrc, which the
    /// encoder would compress trivially and the bloat guard would then discard).
    private func makeFixture(named name: String, seconds: Int = 3, size: String = "640x360") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: BinaryLocator.ffmpegPath())
        process.arguments = [
            "-hide_banner", "-y", "-f", "lavfi",
            "-i", "color=c=gray:s=\(size):r=30,noise=alls=60:allf=t+u",
            "-t", "\(seconds)", "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "12M",
            url.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return url
    }

    private func isTerminal(_ state: JobState) -> Bool {
        switch state {
        case .succeeded, .failed, .cancelled, .discardedAsBlob, .alreadyOptimized: return true
        case .queued, .probing, .planning, .encoding: return false
        }
    }

    private func pollUntilTerminal(_ queue: JobQueue, _ id: UUID, timeout: TimeInterval = 90) async -> Job? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = await queue.job(id: id), isTerminal(job.state) {
                return job
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return await queue.job(id: id)
    }

    /// The reported bug: convert one file, then — only after it has already reached a
    /// terminal state — add a second, different file. It must actually start and run,
    /// not sit in `.queued` forever.
    @Test("a second job added after the first has already finished still runs")
    func secondJobAfterFirstFinishes() async throws {
        let fileA = try makeFixture(named: "a.mp4")
        let fileB = try makeFixture(named: "b.mp4")

        let queue = JobQueue(maxConcurrent: 1)
        let idA = await queue.addJob(url: fileA)

        let jobA = await pollUntilTerminal(queue, idA)
        let stateA = try #require(jobA?.state)
        #expect(stateA == .succeeded, "precondition: the first job must actually finish — got \(stateA)")

        // Only now, with A fully done and out of the active slot, add B.
        let idB = await queue.addJob(url: fileB)

        // If the reported bug is real, B stays `.queued` forever and this times out
        // still `.queued` rather than reaching a terminal state.
        let jobB = await pollUntilTerminal(queue, idB)
        let stateB = try #require(jobB?.state)
        #expect(stateB != .queued, "the second job never started — this is the reported bug")
        #expect(stateB == .succeeded, "the second job should complete like the first, got \(stateB)")
    }

    /// The same scenario the GUI actually exercises: a snapshot-based dedup runs
    /// before each add (MainViewController.enqueue), so prove the sequence survives
    /// that too, not just a bare JobQueue.
    @Test("a second job survives the same snapshot-based dedup the GUI does before adding")
    func secondJobSurvivesGUIStyleDedup() async throws {
        let fileA = try makeFixture(named: "a.mp4")
        let fileB = try makeFixture(named: "b.mp4")

        let queue = JobQueue(maxConcurrent: 1)

        func enqueueLikeTheGUI(_ url: URL) async {
            let seen = Set(await queue.snapshot().map { $0.inputURL.standardizedFileURL })
            guard !seen.contains(url.standardizedFileURL) else { return }
            await queue.addJob(url: url)
        }

        await enqueueLikeTheGUI(fileA)
        let idA = try #require(await queue.snapshot().first?.id)
        let jobA = await pollUntilTerminal(queue, idA)
        #expect(jobA?.state == .succeeded)

        await enqueueLikeTheGUI(fileB)
        let idB = try #require(await queue.snapshot().last?.id)
        #expect(idB != idA, "the dedup must not have swallowed the second, different file")

        let jobB = await pollUntilTerminal(queue, idB)
        #expect(jobB?.state == .succeeded, "got \(String(describing: jobB?.state))")
    }

    /// The other half of the report: drop a second file WHILE the first is still
    /// actively encoding, expecting it to queue rather than being dropped.
    @Test("a second job dropped while the first is still encoding is queued, not lost")
    func secondJobWhileFirstStillEncoding() async throws {
        // Large + slow enough that it's still genuinely encoding a moment later.
        let fileA = try makeFixture(named: "a.mp4", seconds: 8, size: "1280x720")
        let fileB = try makeFixture(named: "b.mp4")

        let queue = JobQueue(maxConcurrent: 1)
        let idA = await queue.addJob(url: fileA)

        // Give A a moment to actually reach .encoding before B arrives.
        var aIsEncoding = false
        for _ in 0..<40 {
            if await queue.job(id: idA)?.state == .encoding { aIsEncoding = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(aIsEncoding, "precondition: A must still be encoding when B is dropped")

        let idB = await queue.addJob(url: fileB)
        #expect(await queue.job(id: idB)?.state == .queued,
                "B should be queued behind the still-running A, not started early")

        let jobA = await pollUntilTerminal(queue, idA)
        #expect(jobA?.state == .succeeded)
        let jobB = await pollUntilTerminal(queue, idB)
        #expect(jobB?.state == .succeeded, "B must run once A frees the slot, got \(String(describing: jobB?.state))")
    }
}
