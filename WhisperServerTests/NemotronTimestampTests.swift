import XCTest
@testable import WhisperServer
import FluidAudio

/// Synthetic finish results exercise timestamp arithmetic, not CoreML inference.
final class NemotronTimestampTests: XCTestCase {
    private let lead: TimeInterval = 4.48
    private let duration: TimeInterval = 10

    private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval, id: Int = 1) -> TokenTiming {
        TokenTiming(token: text, tokenId: id, startTime: start, endTime: end, confidence: 0.95)
    }

    private func restore(_ tokens: [TokenTiming], duration: TimeInterval = 10) -> [TokenTiming] {
        NemotronTranscriptionService.restoreTokenTimings(tokens, leadingPadding: lead, duration: duration)
    }

    private func segments(_ tokens: [TokenTiming], text: String, duration: TimeInterval = 10)
        -> [WhisperSubtitleFormatter.TranscriptionSegment] {
        FluidTranscriptionService.buildSegments(from: tokens, fallbackText: text, duration: duration)
    }

    private func assertBounds(
        _ segments: [WhisperSubtitleFormatter.TranscriptionSegment],
        duration: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(segments.isEmpty, file: file, line: line)
        for segment in segments {
            XCTAssertTrue(segment.startTime.isFinite, file: file, line: line)
            XCTAssertTrue(segment.endTime.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(segment.startTime, 0, file: file, line: line)
            XCTAssertLessThan(segment.startTime, segment.endTime, file: file, line: line)
            XCTAssertLessThanOrEqual(segment.endTime, duration, file: file, line: line)
        }
    }

    func testNemotronTokenCrossingEOFStaysWithinRecording() throws {
        // Review fixture: naive restoration produces 9.98-10.04 after the 60 ms minimum.
        let restored = restore([token("\u{2581}final", 14.46, 14.54)])
        let timing = try XCTUnwrap(restored.first)
        XCTAssertEqual(timing.startTime, 9.94, accuracy: 0.000001)
        XCTAssertEqual(timing.endTime, duration)
        let result = segments(restored, text: "final")
        assertBounds(result)
        XCTAssertEqual(result.map(\.text).joined(), "final")
    }

    func testNemotronFinalWordEmittedInTailIsPreserved() throws {
        // Review fixture: naive restoration produces a cue entirely after EOF.
        let raw = token("\u{2581}final", 14.60, 14.68, id: 42)
        let restored = restore([raw])
        let timing = try XCTUnwrap(restored.first)
        XCTAssertEqual(timing.token, raw.token)
        XCTAssertEqual(timing.tokenId, raw.tokenId)
        XCTAssertEqual(timing.confidence, raw.confidence)
        XCTAssertEqual(timing.startTime, 9.94, accuracy: 0.000001)
        XCTAssertEqual(timing.endTime, duration)
        let result = segments(restored, text: "final")
        assertBounds(result)
        XCTAssertEqual(result.map(\.text).joined(), "final")
    }

    func testNemotronReviewFixturesSerializeWithinEOF() throws {
        for raw in [token("final", 14.46, 14.54), token("final", 14.60, 14.68)] {
            let result = segments(restore([raw]), text: "final")
            let srt = WhisperSubtitleFormatter.formatAsSRT(segments: result)
            let vtt = WhisperSubtitleFormatter.formatAsVTT(segments: result)
            XCTAssertTrue(srt.contains(" --> 00:00:10,000\nfinal"))
            XCTAssertTrue(vtt.contains(" --> 00:00:10.000\nfinal"))
            XCTAssertTrue(srt.contains("00:00:09,"))
            XCTAssertTrue(vtt.contains("00:00:09."))
            let json = WhisperSubtitleFormatter.formatAsVerboseJSON(segments: result)
            let data = try XCTUnwrap(json.data(using: .utf8))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["text"] as? String, "final")
            let entries = try XCTUnwrap(body["segments"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?["end"] as? Double, duration)
        }
    }

    func testNemotronMixedCrossingAndTailTokensKeepWordOrder() {
        let raw = [token("The", 13.8, 14.0, id: 1), token("\u{2581}last", 14.46, 14.54, id: 2),
                   token("\u{2581}word", 14.60, 14.68, id: 3), token(".", 14.68, 14.76, id: 4)]
        let restored = restore(raw)
        XCTAssertEqual(restored.map(\.tokenId), raw.map(\.tokenId))
        let result = segments(restored, text: "The last word.")
        assertBounds(result)
        XCTAssertEqual(result.map(\.text).joined(separator: " "), "The last word.")
    }

    func testNemotronExplicitPaddingDoesNotCreateSubtitles() {
        let restored = restore([token("<pad>", 14.60, 14.68), token("<blank>", 14.68, 14.76),
                                token("", 14.76, 14.84)])
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(segments(restored, text: "").isEmpty)
    }

    func testNemotronPaddingIsRemovedWithoutLosingDelayedSpeech() {
        let restored = restore([token("\u{2581}last", 14.46, 14.54, id: 1),
                                token("<pad>", 14.54, 14.60, id: 2),
                                token("\u{2581}word", 14.60, 14.68, id: 3),
                                token("<blank>", 14.68, 14.76, id: 4)])
        XCTAssertEqual(restored.map(\.tokenId), [1, 3])
        let result = segments(restored, text: "last word")
        assertBounds(result)
        XCTAssertEqual(result.map(\.text).joined(separator: " "), "last word")
    }

    func testNemotronWhitespacePaddingDoesNotExtendLastSpeech() throws {
        let restored = restore([token("Hello", 5.48, 5.98), token("\u{2581}", 14.60, 14.68),
                                token(" \n", 14.68, 14.76)])
        let result = segments(restored, text: "Hello")
        assertBounds(result)
        XCTAssertEqual(result.count, 1)
        let segment = try XCTUnwrap(result.first)
        XCTAssertEqual(segment.text, "Hello")
        XCTAssertEqual(segment.startTime, 1, accuracy: 0.000001)
        XCTAssertEqual(segment.endTime, 1.5, accuracy: 0.000001)
    }

    func testNemotronStandaloneWordSeparatorIsPreserved() {
        let restored = restore([token("Hello", 5.48, 5.98), token("\u{2581}", 5.98, 6.06),
                                token("world", 6.06, 6.48)])
        let result = segments(restored, text: "Hello world")
        assertBounds(result)
        XCTAssertEqual(result.map(\.text).joined(separator: " "), "Hello world")
    }

    func testNemotronWhitespaceOnlyResultHasNoSubtitles() {
        let restored = restore([token("\u{2581}", 14.60, 14.68), token(" \n", 14.68, 14.76)])
        XCTAssertTrue(segments(restored, text: " \n").isEmpty)
    }

    func testNemotronDelayedFinalWordRemainsAvailableForDiarization() throws {
        let restored = restore([token("\u{2581}last", 14.46, 14.54), token("\u{2581}word", 14.60, 14.68)])
        let speakers = [TimedSpeakerSegment(speakerId: "Speaker_1", embedding: [],
                                           startTimeSeconds: 9, endTimeSeconds: 10, qualityScore: 0.95)]
        let result = FluidTranscriptionService.mapDiarizationSegments(speakers, tokens: restored, duration: duration)
        let segment = try XCTUnwrap(result.first)
        XCTAssertEqual(segment.text, "last word")
        XCTAssertEqual(segment.endTime, duration)
    }

    func testNemotronInRangeTimingsKeepOriginalOffset() throws {
        let restored = restore([token("Hello", 5.48, 6.48)])
        let timing = try XCTUnwrap(restored.first)
        XCTAssertEqual(timing.startTime, 1, accuracy: 0.000001)
        XCTAssertEqual(timing.endTime, 2, accuracy: 0.000001)
    }

    func testNemotronLeadingBoundaryIsClampedWithoutDroppingText() {
        let restored = restore([token("Hello", 4.46, 4.54)])
        let result = segments(restored, text: "Hello")
        assertBounds(result)
        XCTAssertEqual(result.first?.startTime, 0)
        XCTAssertEqual(result.first?.text, "Hello")
    }

    func testFluidFormatterIndependentlyBoundsUnrestoredLateTokens() {
        for raw in [token("final", 9.98, 10.06), token("final", 10.12, 10.20)] {
            let result = segments([raw], text: "final")
            assertBounds(result)
            XCTAssertEqual(result.first?.text, "final")
        }
    }

    func testFluidFallbackNeverExtendsShortRecording() throws {
        for duration in [1.0 / 16_000, 0.01, 0.059, 0.06, 0.1] {
            let result = segments([], text: "Hello", duration: duration)
            assertBounds(result, duration: duration)
            XCTAssertEqual(try XCTUnwrap(result.first).endTime, duration)
        }
    }

    func testNemotronShortRecordingAndBoundaryGridRemainValid() {
        for duration in [1.0 / 16_000, 0.01, 0.059, 0.06, 0.061, 1, 10, 123.456] {
            for offset in [-0.08, 0, duration / 2, duration - 0.02, duration, duration + 0.12, duration + 2.24] {
                let restored = restore([token("word", lead + offset, lead + offset + 0.08)], duration: duration)
                for timing in restored {
                    XCTAssertGreaterThanOrEqual(timing.startTime, 0)
                    XCTAssertLessThan(timing.startTime, timing.endTime)
                    XCTAssertLessThanOrEqual(timing.endTime, duration)
                }
                let result = segments(restored, text: "word", duration: duration)
                assertBounds(result, duration: duration)
                XCTAssertEqual(result.first?.text, "word")
            }
        }
    }

    func testNemotronInvalidTimingsUseCompleteTextFallback() {
        for invalid in [token(" word", .nan, 15), token(" word", 14.6, .infinity), token(" word", 15, 14)] {
            let restored = restore([token("Last", 13.8, 14), invalid])
            XCTAssertTrue(restored.isEmpty)
            let result = segments(restored, text: "Last word")
            assertBounds(result)
            XCTAssertEqual(result.first?.text, "Last word")
        }
    }

    func testFluidInvalidTimingDoesNotSilentlyLosePartOfTranscript() {
        let result = segments([token("Last", 9, 9.5), token(" word", .nan, 10)], text: "Last word")
        assertBounds(result)
        XCTAssertEqual(result.first?.text, "Last word")
    }

    func testFluidInvalidDurationProducesNoSubtitles() {
        for duration in [0, -1, TimeInterval.nan, .infinity] {
            XCTAssertTrue(segments([], text: "Hello", duration: duration).isEmpty)
            XCTAssertTrue(segments([token("Hello", 0, 1)], text: "Hello", duration: duration).isEmpty)
            XCTAssertTrue(restore([token("Hello", 5, 6)], duration: duration).isEmpty)
        }
    }

    func testNemotronInvalidLeadingPaddingUsesFallback() {
        for padding in [-1, TimeInterval.nan, .infinity] {
            XCTAssertTrue(NemotronTranscriptionService.restoreTokenTimings(
                [token("Hello", 5, 6)], leadingPadding: padding, duration: duration).isEmpty)
        }
    }
}
