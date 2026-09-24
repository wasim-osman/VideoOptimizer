// BloatGuardTests.swift - The two defences against producing a larger file (spec §2.2).

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("BloatGuard")
struct BloatGuardTests {
    private let bloatGuard = BloatGuard()

    // MARK: - BPP floors

    @Test("floors are ordered by codec efficiency")
    func floorsAreOrdered() {
        let h264 = BloatGuard.bppFloor(forCodec: "h264")
        let hevc = BloatGuard.bppFloor(forCodec: "hevc")
        let av1 = BloatGuard.bppFloor(forCodec: "av1")
        #expect(h264 > hevc, "H.264 needs more bits per pixel than HEVC for the same look")
        #expect(hevc > av1, "HEVC needs more bits per pixel than AV1")
    }

    @Test("codec aliases and casing map to the same floor")
    func floorMatchesAliases() {
        // ffprobe reports the same codec under several names depending on container.
        #expect(BloatGuard.bppFloor(forCodec: "avc1") == BloatGuard.bppFloor(forCodec: "h264"))
        #expect(BloatGuard.bppFloor(forCodec: "hvc1") == BloatGuard.bppFloor(forCodec: "hevc"))
        #expect(BloatGuard.bppFloor(forCodec: "HEVC") == BloatGuard.bppFloor(forCodec: "hevc"),
                "codec matching must be case-insensitive")
    }

    // MARK: - Pre-flight

    @Test("a bloated source proceeds")
    func bloatedSourceProceeds() {
        #expect(bloatGuard.preflight(Fixtures.h264_1080p(bitrate: 12_000_000)) == .proceed)
    }

    @Test("an already-efficient source is refused")
    func efficientSourceIsRefused() {
        guard case .alreadyOptimised = bloatGuard.preflight(Fixtures.efficientHEVC()) else {
            Issue.record("a source below the BPP floor must be refused")
            return
        }
    }

    @Test("a file with no video stream is refused")
    func missingVideoStreamIsRefused() {
        guard case .alreadyOptimised = bloatGuard.preflight(MediaInfo()) else {
            Issue.record("a file with no video stream must be refused")
            return
        }
    }

    /// When ffprobe cannot determine a bitrate at any level, BPP is unknowable.
    /// Unknown must not be read as "efficient" — that refuses files silently and wrongly.
    @Test("an undeterminable bitrate proceeds rather than being refused")
    func unknownBitrateProceeds() {
        let media = Fixtures.unknownBitrate()
        #expect(media.bpp == 0, "precondition: this fixture has no derivable bitrate")
        #expect(bloatGuard.preflight(media) == .proceed,
                "unknown BPP must fall through to encoding, not be refused as already-optimised")
    }

    // MARK: - Post-flight

    @Test("an output at or above 92% of the source is discarded")
    func postFlightDiscards() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 1000))
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 920))
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 1500),
                "a larger output is the exact failure this guard exists to prevent")
    }

    @Test("a worthwhile saving is kept")
    func postFlightKeepsSavings() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 919) == false)
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 1000, outputSize: 400) == false)
    }

    @Test("an unknown input size does not discard a real output")
    func postFlightHandlesUnknownInputSize() {
        #expect(BloatGuard.postFlightShouldDiscard(inputSize: 0, outputSize: 500) == false)
    }

    // MARK: - BPP derivation

    @Test("BPP uses width, height and frame rate")
    func bppDerivation() {
        // 12_000_000 / (1920*1080) / 30
        #expect(abs(Fixtures.h264_1080p(bitrate: 12_000_000, fps: 30).bpp - 0.1929) < 0.0005)
    }

    @Test("a missing frame rate yields zero rather than infinity")
    func bppIsSafeWithoutFrameRate() {
        var media = Fixtures.h264_1080p()
        media.video.fps = 0
        #expect(media.bpp == 0)
    }
}
