// IdleSummaryTests.swift - What the drop zone shows once nothing is actively converting.
//
// This is a direct regression test for a real report: a file refused by the bloat
// guard ("already optimised") used to show a blank detail line, with no indication at
// all of why nothing was produced — easy to mistake for the app having done nothing.

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("IdleSummary")
struct IdleSummaryTests {

    private func job(state: JobState, error: String = "", inputSize: Int64 = 0,
                      resultSize: Int64? = nil) -> Job {
        var job = Job(inputURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mp4"))
        job.state = state
        job.error = error
        job.inputSize = inputSize
        job.resultSize = resultSize
        return job
    }

    @Test("no jobs at all shows the plain drop prompt")
    func noJobs() {
        #expect(IdleSummary.headline(for: []) == "Drop video files here")
        #expect(IdleSummary.detail(for: []) == "")
    }

    // MARK: - The actual regression

    @Test("an already-optimised job's reason is shown, not a blank line")
    func alreadyOptimizedShowsItsReason() {
        let jobs = [job(state: .alreadyOptimized, error: "0.0420 bits/pixel/frame is below the 0.045 floor for h264.")]
        #expect(IdleSummary.headline(for: jobs) == "1 already optimised")
        #expect(IdleSummary.detail(for: jobs) == "0.0420 bits/pixel/frame is below the 0.045 floor for h264.",
                "the whole point: this must not be blank just because nothing failed outright")
    }

    @Test("a discarded-as-blob job's reason is shown too")
    func discardedAsBlobShowsItsReason() {
        let jobs = [job(state: .discardedAsBlob, error: "Output was ≥92% of the input.")]
        #expect(IdleSummary.headline(for: jobs) == "1 already optimised")
        #expect(IdleSummary.detail(for: jobs) == "Output was ≥92% of the input.")
    }

    @Test("a failed job's error is shown (the one case that already worked)")
    func failedShowsItsError() {
        let jobs = [job(state: .failed, error: "ffprobe failed: invalid data")]
        #expect(IdleSummary.headline(for: jobs) == "1 failed")
        #expect(IdleSummary.detail(for: jobs) == "ffprobe failed: invalid data")
    }

    @Test("a cancelled-only batch has no specific reason to show, and that's fine")
    func cancelledAloneHasNoDetail() {
        let jobs = [job(state: .cancelled)]
        #expect(IdleSummary.headline(for: jobs) == "1 stopped")
        #expect(IdleSummary.detail(for: jobs) == "")
    }

    // MARK: - Priority when a batch mixes outcomes

    @Test("a succeeded batch's before/after summary takes priority over any refusal")
    func succeededTakesPriorityOverRefusals() {
        let jobs = [
            job(state: .succeeded, inputSize: 1000, resultSize: 400),
            job(state: .alreadyOptimized, error: "should not appear"),
        ]
        let detail = IdleSummary.detail(for: jobs)
        #expect(detail.contains("should not appear") == false)
        #expect(detail.contains("→"), "got \(detail)")
        #expect(detail.contains("click to show in Finder"))
    }

    @Test("the most recent refusal's reason wins when there are several")
    func mostRecentRefusalWins() {
        let jobs = [
            job(state: .alreadyOptimized, error: "first file's reason"),
            job(state: .alreadyOptimized, error: "second file's reason"),
        ]
        #expect(IdleSummary.detail(for: jobs) == "second file's reason")
        #expect(IdleSummary.headline(for: jobs) == "2 already optimised")
    }

    @Test("every bucket in the headline is counted independently")
    func headlineCountsEveryBucket() {
        let jobs = [
            job(state: .succeeded, inputSize: 100, resultSize: 40),
            job(state: .succeeded, inputSize: 100, resultSize: 40),
            job(state: .alreadyOptimized, error: "x"),
            job(state: .discardedAsBlob, error: "y"),
            job(state: .failed, error: "z"),
            job(state: .cancelled),
        ]
        let headline = IdleSummary.headline(for: jobs)
        #expect(headline.contains("2 converted"))
        #expect(headline.contains("2 already optimised"), "alreadyOptimized + discardedAsBlob both count as skipped")
        #expect(headline.contains("1 stopped"))
        #expect(headline.contains("1 failed"))
    }

    // MARK: - The pre-existing succeeded-batch formatting, unchanged by this fix

    @Test("a succeeded batch sums before/after across every converted job")
    func succeededBatchSumsAcrossJobs() {
        let jobs = [
            job(state: .succeeded, inputSize: 1_000_000, resultSize: 400_000),
            job(state: .succeeded, inputSize: 2_000_000, resultSize: 900_000),
        ]
        let detail = IdleSummary.detail(for: jobs)
        // 3,000,000 -> 1,300,000 is a 56.67% reduction, rounds down to 56%.
        #expect(detail.contains("(−56%)"), "got \(detail)")
    }

    @Test("a succeeded job with no known input size produces no detail, not a crash")
    func succeededWithZeroInputSizeIsSafe() {
        let jobs = [job(state: .succeeded, inputSize: 0, resultSize: 0)]
        #expect(IdleSummary.detail(for: jobs) == "")
    }

    @Test("a succeeded job missing resultSize falls back to its input size, not a 0% claim")
    func missingResultSizeFallsBackToInputSize() {
        let jobs = [job(state: .succeeded, inputSize: 1000, resultSize: nil)]
        #expect(IdleSummary.detail(for: jobs).contains("(−0%)"))
    }
}
