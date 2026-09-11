import XCTest
@testable import WhisperServer

final class WhisperTranscriptionFailureTests: XCTestCase {
    private enum Output {
        case text
        case segments

        var printsTimestamps: Bool { self == .segments }
    }

    private final class Fixture {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        var context: OpaquePointer { OpaquePointer(storage) }
        var state = WhisperContextLifecycleState()
        var isolated = false
        var acquisitionFails = false
        var reinitializeDuringInference = false
        var changeModeDuringInference = false
        var inferenceResult: Int32 = -1
        var modeReads = 0
        var sharedAcquisitions = 0
        var sharedReleases = 0
        var isolatedCreations = 0
        var isolatedFrees = 0
        var deferredFrees = 0
        var inferenceCalls = 0
        var segmentReads = 0
        var events: [String] = []

        deinit { storage.deallocate() }

        func dependencies(for output: Output) -> WhisperTranscriptionService.ChunkDependencies {
            WhisperTranscriptionService.ChunkDependencies(
                usesIsolatedContext: {
                    self.modeReads += 1
                    return self.isolated
                },
                acquireSharedContext: { paths in
                    XCTAssertNil(paths)
                    self.sharedAcquisitions += 1
                    self.events.append("acquire")
                    guard !self.acquisitionFails else { return nil }
                    self.state.acquire()
                    return self.context
                },
                releaseSharedContext: {
                    self.sharedReleases += 1
                    self.events.append("release")
                    XCTAssertEqual(self.state.activeUseCount, 1)
                    if self.state.release() { self.deferredFrees += 1 }
                },
                createIsolatedContext: { paths in
                    XCTAssertNil(paths)
                    self.isolatedCreations += 1
                    self.events.append("create")
                    return self.acquisitionFails ? nil : self.context
                },
                freeIsolatedContext: { context in
                    XCTAssertEqual(context, self.context)
                    self.isolatedFrees += 1
                    self.events.append("free")
                },
                runInference: { context, params, samples, count in
                    self.inferenceCalls += 1
                    self.events.append("infer")
                    XCTAssertEqual(context, self.context)
                    XCTAssertEqual(count, 3)
                    let receivedSamples = Array(UnsafeBufferPointer(start: samples, count: Int(count)))
                    XCTAssertEqual(receivedSamples, [0.125, -0.25, 0.5])
                    XCTAssertEqual(params.language.map { String(cString: $0) }, "ru")
                    XCTAssertEqual(params.initial_prompt.map { String(cString: $0) }, "Test prompt")
                    XCTAssertEqual(params.print_timestamps, output.printsTimestamps)
                    XCTAssertEqual(self.state.activeUseCount, self.isolated ? 0 : 1)
                    XCTAssertEqual(self.sharedReleases, 0)
                    XCTAssertEqual(self.isolatedFrees, 0)
                    if self.reinitializeDuringInference {
                        XCTAssertFalse(self.state.canReleaseForInactivity())
                        XCTAssertFalse(self.state.requestReinitialization())
                    }
                    if self.changeModeDuringInference { self.isolated.toggle() }
                    return self.inferenceResult
                },
                segmentCount: { context in
                    XCTAssertEqual(context, self.context)
                    XCTAssertEqual(self.sharedReleases, 0, "Lease must also protect result extraction")
                    XCTAssertEqual(self.isolatedFrees, 0)
                    self.segmentReads += 1
                    self.events.append("segments")
                    return 0
                }
            )
        }
    }

    /// Calls the real production entry points, not a test-side copy of their defer blocks.
    @discardableResult
    private func transcribe(_ output: Output, using fixture: Fixture) -> Bool {
        let samples: [Float] = [0.125, -0.25, 0.5]
        let dependencies = fixture.dependencies(for: output)
        switch output {
        case .text:
            return WhisperTranscriptionService.transcribeChunk(
                samples, language: "ru", prompt: "Test prompt", modelPaths: nil,
                dependencies: dependencies
            ) != nil
        case .segments:
            return WhisperTranscriptionService.transcribeChunkToSegments(
                samples, chunkStartTime: 10, language: "ru", prompt: "Test prompt", modelPaths: nil,
                dependencies: dependencies
            ) != nil
        }
    }

    private func assertSharedFailure(_ output: Output, reinitialize: Bool = false,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for status: Int32 in [-1, 1, -7] {
            let fixture = Fixture()
            fixture.inferenceResult = status
            fixture.reinitializeDuringInference = reinitialize
            XCTAssertFalse(transcribe(output, using: fixture), file: file, line: line)
            XCTAssertEqual(fixture.events, ["acquire", "infer", "release"], file: file, line: line)
            XCTAssertEqual(fixture.sharedAcquisitions, 1, file: file, line: line)
            XCTAssertEqual(fixture.sharedReleases, 1, file: file, line: line)
            XCTAssertEqual(fixture.inferenceCalls, 1, file: file, line: line)
            XCTAssertEqual(fixture.segmentReads, 0, file: file, line: line)
            XCTAssertEqual(fixture.isolatedCreations, 0, file: file, line: line)
            XCTAssertEqual(fixture.isolatedFrees, 0, file: file, line: line)
            XCTAssertEqual(fixture.state.activeUseCount, 0, file: file, line: line)
            XCTAssertFalse(fixture.state.pendingFree, file: file, line: line)
            XCTAssertTrue(fixture.state.canReleaseForInactivity(), file: file, line: line)
            XCTAssertEqual(fixture.deferredFrees, reinitialize ? 1 : 0, file: file, line: line)
        }
    }

    func testTextFailureReleasesSharedLeaseExactlyOnce() { assertSharedFailure(.text) }
    func testSegmentFailureReleasesSharedLeaseExactlyOnce() { assertSharedFailure(.segments) }
    func testTextFailureCompletesDeferredReinitialization() { assertSharedFailure(.text, reinitialize: true) }
    func testSegmentFailureCompletesDeferredReinitialization() { assertSharedFailure(.segments, reinitialize: true) }

    func testFailedAcquisitionDoesNotInferOrRelease() {
        for output in [Output.text, .segments] {
            for isolated in [false, true] {
                let fixture = Fixture()
                fixture.isolated = isolated
                fixture.acquisitionFails = true
                XCTAssertFalse(transcribe(output, using: fixture))
                XCTAssertEqual(fixture.events, [isolated ? "create" : "acquire"])
                XCTAssertEqual(fixture.sharedAcquisitions, isolated ? 0 : 1)
                XCTAssertEqual(fixture.isolatedCreations, isolated ? 1 : 0)
                XCTAssertEqual(fixture.inferenceCalls, 0)
                XCTAssertEqual(fixture.segmentReads, 0)
                XCTAssertEqual(fixture.sharedReleases, 0)
                XCTAssertEqual(fixture.isolatedFrees, 0)
                XCTAssertEqual(fixture.state.activeUseCount, 0)
            }
        }
    }

    func testIsolatedInferenceFailureFreesOnlyIsolatedContext() {
        for output in [Output.text, .segments] {
            let fixture = Fixture()
            fixture.isolated = true
            XCTAssertFalse(transcribe(output, using: fixture))
            XCTAssertEqual(fixture.events, ["create", "infer", "free"])
            XCTAssertEqual(fixture.isolatedCreations, 1)
            XCTAssertEqual(fixture.isolatedFrees, 1)
            XCTAssertEqual(fixture.sharedAcquisitions, 0)
            XCTAssertEqual(fixture.sharedReleases, 0)
            XCTAssertEqual(fixture.state.activeUseCount, 0)
            XCTAssertEqual(fixture.segmentReads, 0)
        }
    }

    func testModeChangeDuringInferencePreservesAcquiredOwnership() {
        for output in [Output.text, .segments] {
            for initiallyIsolated in [false, true] {
                let fixture = Fixture()
                fixture.isolated = initiallyIsolated
                fixture.changeModeDuringInference = true
                XCTAssertFalse(transcribe(output, using: fixture))
                XCTAssertEqual(fixture.modeReads, 1, "Cleanup must not reread a mutable setting")
                XCTAssertEqual(fixture.isolated, !initiallyIsolated)
                XCTAssertEqual(fixture.sharedReleases, initiallyIsolated ? 0 : 1)
                XCTAssertEqual(fixture.isolatedFrees, initiallyIsolated ? 1 : 0)
                XCTAssertEqual(fixture.state.activeUseCount, 0)
                let expectedEvents = initiallyIsolated ? ["create", "infer", "free"] : ["acquire", "infer", "release"]
                XCTAssertEqual(fixture.events, expectedEvents)
            }
        }
    }

    func testSuccessRetainsContextUntilResultExtractionCompletes() {
        for output in [Output.text, .segments] {
            for isolated in [false, true] {
                let fixture = Fixture()
                fixture.isolated = isolated
                fixture.inferenceResult = 0
                XCTAssertTrue(transcribe(output, using: fixture))
                let expectedEvents = isolated
                    ? ["create", "infer", "segments", "free"]
                    : ["acquire", "infer", "segments", "release"]
                XCTAssertEqual(fixture.events, expectedEvents)
                XCTAssertEqual(fixture.segmentReads, 1)
                XCTAssertEqual(fixture.sharedReleases, isolated ? 0 : 1)
                XCTAssertEqual(fixture.isolatedFrees, isolated ? 1 : 0)
                XCTAssertEqual(fixture.state.activeUseCount, 0)
            }
        }
    }
}
