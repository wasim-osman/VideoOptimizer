// ProgressParserTests.swift - Parsing the real `-progress pipe:1 -nostats` stream.
//
// The sample below is captured verbatim from ffmpeg 8.x. Note what it does NOT
// contain: blank lines. Blocks are delimited by the `progress=` line itself.

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("ProgressParser")
struct ProgressParserTests {

    /// Two complete blocks exactly as ffmpeg writes them.
    static let realStream = """
    frame=42
    fps=0.00
    stream_0_0_q=29.0
    bitrate=   0.3kbits/s
    total_size=48
    out_time_us=1333333
    out_time_ms=1333333
    out_time=00:00:01.333333
    dup_frames=0
    drop_frames=0
    speed=2.64x
    progress=continue
    frame=150
    fps=148.59
    stream_0_0_q=29.0
    bitrate=   0.1kbits/s
    total_size=48
    out_time_us=4933333
    out_time_ms=4933333
    out_time=00:00:04.933333
    dup_frames=0
    drop_frames=0
    speed=4.89x
    progress=continue
    """

    private func parse(_ text: String) -> ProgressParser {
        var parser = ProgressParser()
        for line in text.split(separator: "\n") {
            parser.feed(line: String(line))
        }
        return parser
    }

    /// The headline regression: a real stream must move the progress value off zero.
    @Test("a real ffmpeg stream produces progress")
    func realStreamProducesProgress() {
        let parser = parse(Self.realStream)
        #expect(parser.latest.frame == 150, "should hold the most recent complete block")
        #expect(abs(parser.latest.outTimeMicros - 4_933_333) < 1)
        #expect(abs(parser.latest.speed - 4.89) < 0.001)
        #expect(parser.latest.done == false)
    }

    @Test("percent is computed against a known duration")
    func percentAgainstKnownDuration() {
        // 4.933333s of a 20s source.
        let percent = parse(Self.realStream).latest.percent(duration: 20)
        #expect(abs(percent - 0.2466) < 0.001)
    }

    /// A block is complete at `progress=continue` — not at some later blank line.
    @Test("the first block is readable before a second one arrives")
    func firstBlockCommitsAtProgressContinue() {
        let firstBlock = Self.realStream.split(separator: "\n").prefix(12).joined(separator: "\n")
        let parser = parse(firstBlock)
        #expect(parser.latest.frame == 42)
        #expect(abs(parser.latest.outTimeMicros - 1_333_333) < 1)
    }

    @Test("progress=end marks completion")
    func progressEndSetsDone() {
        let parser = parse("frame=600\nout_time_us=20000000\nspeed=5.0x\nprogress=end")
        #expect(parser.latest.done)
        #expect(abs(parser.latest.percent(duration: 20) - 1.0) < 0.001)
    }

    /// Reads come off the pipe in arbitrary chunks; a block split mid-way must still land.
    @Test("an unterminated block is not published early")
    func partialBlockIsNotCommittedEarly() {
        var parser = ProgressParser()
        for line in ["frame=42", "fps=0.00", "out_time_us=1333333"] {
            parser.feed(line: line)
        }
        #expect(parser.latest.frame == 0, "an unterminated block must not be published")

        parser.feed(line: "speed=2.64x")
        parser.feed(line: "progress=continue")
        #expect(parser.latest.frame == 42, "and must publish once its terminator arrives")
    }

    @Test("percent is clamped and safe with an unknown duration")
    func percentIsClampedAndSafe() {
        let parser = parse("out_time_us=999000000\nprogress=continue")
        #expect(parser.latest.percent(duration: 20) == 1.0, "percent must never exceed 1")
        #expect(parser.latest.percent(duration: 0) == 0.0, "unknown duration must not divide by zero")
    }
}
