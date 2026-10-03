// ForceConvertTests.swift - "Convert anyway?" after a file was already refused once.

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("ForceConvert")
struct ForceConvertTests {
    private let url = URL(fileURLWithPath: "/tmp/clip.mp4")
    private let otherURL = URL(fileURLWithPath: "/tmp/other.mp4")

    private func job(url: URL, state: JobState, error: String = "") -> Job {
        var job = Job(inputURL: url)
        job.state = state
        job.error = error
        return job
    }

    @Test("no history at all means no prompt")
    func noHistory() {
        #expect(ForceConvert.shouldPromptToForce(url: url, among: []) == nil)
    }

    @Test("a prior already-optimised refusal of this exact file prompts")
    func priorAlreadyOptimizedPrompts() {
        let jobs = [job(url: url, state: .alreadyOptimized, error: "bpp too low")]
        let found = ForceConvert.shouldPromptToForce(url: url, among: jobs)
        #expect(found?.error == "bpp too low")
    }

    @Test("a prior discarded-as-blob refusal of this exact file prompts too")
    func priorDiscardedAsBlobPrompts() {
        let jobs = [job(url: url, state: .discardedAsBlob, error: "output too big")]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs)?.error == "output too big")
    }

    @Test("a refusal of a DIFFERENT file never prompts for this one",
          arguments: [JobState.alreadyOptimized, .discardedAsBlob])
    func differentFileNeverPrompts(state: JobState) {
        let jobs = [job(url: otherURL, state: state, error: "x")]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs) == nil)
    }

    @Test("every other past state for this exact file does not prompt",
          arguments: [JobState.queued, .probing, .planning, .encoding, .succeeded, .failed, .cancelled])
    func otherStatesDoNotPrompt(state: JobState) {
        let jobs = [job(url: url, state: state, error: "irrelevant")]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs) == nil,
                "a \(state) job must never trigger the force-convert prompt")
    }

    @Test("the most recent refusal of this file is the one surfaced")
    func mostRecentRefusalWins() {
        let jobs = [
            job(url: url, state: .alreadyOptimized, error: "first attempt's reason"),
            job(url: url, state: .discardedAsBlob, error: "second attempt's reason"),
        ]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs)?.error == "second attempt's reason")
    }

    @Test("a later succeeded attempt (e.g. after settings changed) clears the prompt")
    func laterSuccessClearsIt() {
        let jobs = [
            job(url: url, state: .alreadyOptimized, error: "was refused"),
            job(url: url, state: .succeeded),
        ]
        #expect(ForceConvert.shouldPromptToForce(url: url, among: jobs) == nil,
                "once it has actually succeeded since, there is nothing left to force")
    }

    @Test("file path comparison is standardized, matching how drops are deduplicated elsewhere")
    func standardizesThePath() {
        let messy = URL(fileURLWithPath: "/tmp/../tmp/./clip.mp4")
        let jobs = [job(url: url, state: .alreadyOptimized, error: "x")]
        #expect(ForceConvert.shouldPromptToForce(url: messy, among: jobs) != nil)
    }
}
