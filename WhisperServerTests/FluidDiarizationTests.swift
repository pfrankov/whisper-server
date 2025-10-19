import XCTest
@testable import WhisperServer
import FluidAudio

final class FluidDiarizationTests: XCTestCase {
    func testMapsTokensIntoSpeakerSegments() {
        let tokens: [TokenTiming] = [
            TokenTiming(token: " second", tokenId: 3, startTime: 1.2, endTime: 1.8, confidence: 0.95),
            TokenTiming(token: " speaker", tokenId: 4, startTime: 1.8, endTime: 2.3, confidence: 0.92),
            TokenTiming(token: "Hello", tokenId: 0, startTime: 0.0, endTime: 0.3, confidence: 0.99),
            TokenTiming(token: " there", tokenId: 1, startTime: 0.3, endTime: 0.8, confidence: 0.97),
            TokenTiming(token: "!", tokenId: 2, startTime: 0.8, endTime: 1.05, confidence: 0.93),
            TokenTiming(token: " again", tokenId: 5, startTime: 2.3, endTime: 2.8, confidence: 0.9)
        ]

        let diarizationSegments: [TimedSpeakerSegment] = [
            TimedSpeakerSegment(
                speakerId: "Speaker_1",
                embedding: [],
                startTimeSeconds: 0.0,
                endTimeSeconds: 1.1,
                qualityScore: 0.95
            ),
            TimedSpeakerSegment(
                speakerId: "Speaker_2",
                embedding: [],
                startTimeSeconds: 1.2,
                endTimeSeconds: 2.9,
                qualityScore: 0.9
            )
        ]

        let result = FluidTranscriptionService.mapDiarizationSegments(
            diarizationSegments,
            tokens: tokens,
            duration: 3.0
        )

        XCTAssertEqual(result.count, 2)

        let first = result[0]
        XCTAssertEqual(first.speakerId, "Speaker_1")
        XCTAssertEqual(first.text, "Hello there!")
        XCTAssertEqual(first.startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(first.endTime, 1.1, accuracy: 0.001)

        let second = result[1]
        XCTAssertEqual(second.speakerId, "Speaker_2")
        XCTAssertEqual(second.text, "second speaker again")
        XCTAssertEqual(second.startTime, 1.2, accuracy: 0.001)
        XCTAssertEqual(second.endTime, 2.9, accuracy: 0.001)
    }
}
