// CRFLadderTests.swift - The resolution/content CRF table (spec §2.3).

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("CRFLadder")
struct CRFLadderTests {
    private let ladder = CRFLadder()

    /// Higher resolutions tolerate a higher CRF for the same perceived quality.
    @Test("CRF rises monotonically with resolution", arguments: [EncoderKind.x264, .x265, .av1])
    func crfRisesWithResolution(encoder: EncoderKind) {
        let heights = [480, 720, 1080, 1440, 2160]
        let values = heights.map { ladder.baseCRF(for: $0, encoder: encoder) }
        #expect(values == values.sorted(),
                "\(encoder) ladder must not decrease as resolution rises: \(values)")
        #expect(values.last! > values.first!,
                "\(encoder) ladder must actually vary with resolution")
    }

    @Test("each encoder has its own CRF scale")
    func encoderScalesAreDistinct() {
        // AV1's CRF scale is coarser than x265's, which is coarser than x264's.
        #expect(ladder.baseCRF(for: 1080, encoder: .av1) > ladder.baseCRF(for: 1080, encoder: .x265))
        #expect(ladder.baseCRF(for: 1080, encoder: .x265) > ladder.baseCRF(for: 1080, encoder: .x264))
    }

    @Test("boundary heights land on the expected rung")
    func boundaryHeights() {
        // 1080 belongs to the 1080 rung; 1081 must fall to the next one up.
        #expect(ladder.baseCRF(for: 1080, encoder: .x265) == 21)
        #expect(ladder.baseCRF(for: 1081, encoder: .x265) == 22)
        #expect(ladder.baseCRF(for: 720, encoder: .x265) == 20)
    }

    @Test("content adjustments move in the right direction")
    func contentAdjustments() {
        let base = ladder.baseCRF(for: 1080, encoder: .x265)
        #expect(ladder.adjustedCRF(base: base, profile: .heavyGrain) > base,
                "grain is expensive and perceptually forgiving — spend fewer bits")
        #expect(ladder.adjustedCRF(base: base, profile: .screenCapture) < base,
                "flat screen content shows artefacts badly — spend more bits")
        #expect(ladder.adjustedCRF(base: base, profile: .animation) < base)
        #expect(ladder.adjustedCRF(base: base, profile: .general) == base)
    }

    @Test("the user quality offset is applied")
    func userOffsetIsApplied() {
        let neutral = ladder.crf(for: 1080, profile: .general, encoder: .x265, qualityOffset: 0)
        #expect(ladder.crf(for: 1080, profile: .general, encoder: .x265, qualityOffset: -3) == neutral - 3)
        #expect(ladder.crf(for: 1080, profile: .general, encoder: .x265, qualityOffset: 3) == neutral + 3)
    }

    @Test("CRF is clamped to a sane band")
    func crfIsClamped() {
        #expect(ladder.crf(for: 480, profile: .screenCapture, encoder: .x264, qualityOffset: -50) >= 10)
        #expect(ladder.crf(for: 4320, profile: .heavyGrain, encoder: .av1, qualityOffset: 50) <= 40)
    }

    // MARK: - Classification

    @Test("a very high bitrate source is classified as grainy")
    func highBitrateIsGrainy() {
        #expect(ladder.classify(Fixtures.h264_1080p(bitrate: 40_000_000)) == .heavyGrain)
    }

    @Test("an ordinary source is classified general")
    func ordinaryIsGeneral() {
        #expect(ladder.classify(Fixtures.h264_1080p(bitrate: 6_000_000)) == .general)
    }

    @Test("classification is safe on an empty MediaInfo")
    func classificationIsSafe() {
        #expect(ladder.classify(MediaInfo()) == .general)
    }
}
