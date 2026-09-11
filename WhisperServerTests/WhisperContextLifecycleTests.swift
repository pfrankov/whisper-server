import XCTest
@testable import WhisperServer

final class WhisperContextLifecycleTests: XCTestCase {
    func testTimeoutDuringActiveLeaseDoesNotAllowFree() {
        var state = WhisperContextLifecycleState()
        XCTAssertTrue(state.canReleaseForInactivity())
        state.acquire()
        XCTAssertEqual(state.activeUseCount, 1)
        XCTAssertFalse(state.canReleaseForInactivity())
        XCTAssertFalse(state.pendingFree)
        XCTAssertFalse(state.release())
        XCTAssertEqual(state.activeUseCount, 0)
        XCTAssertTrue(state.canReleaseForInactivity())
    }

    func testReinitializationIsDeferredUntilLastLeaseReleases() {
        var state = WhisperContextLifecycleState()
        state.acquire()
        state.acquire()
        XCTAssertFalse(state.requestReinitialization())
        XCTAssertTrue(state.pendingFree)
        XCTAssertEqual(state.activeUseCount, 2)
        XCTAssertFalse(state.release(), "The first release must not free a context still used by another lease")
        XCTAssertTrue(state.pendingFree)
        XCTAssertEqual(state.activeUseCount, 1)
        XCTAssertTrue(state.release(), "The final release must perform the deferred reinitialization free")
        XCTAssertFalse(state.pendingFree)
        XCTAssertEqual(state.activeUseCount, 0)
    }

    func testIdleReinitializationCanFreeImmediately() {
        var state = WhisperContextLifecycleState()
        XCTAssertTrue(state.requestReinitialization())
        XCTAssertFalse(state.pendingFree)
        XCTAssertEqual(state.activeUseCount, 0)
    }

    func testRepeatedReinitializationFreesOnlyOnce() {
        var state = WhisperContextLifecycleState()
        state.acquire()
        XCTAssertFalse(state.requestReinitialization())
        XCTAssertFalse(state.requestReinitialization())
        XCTAssertTrue(state.release())
        XCTAssertFalse(state.release())
        XCTAssertFalse(state.pendingFree)
        XCTAssertEqual(state.activeUseCount, 0)
        state.acquire()
        XCTAssertFalse(state.release(), "A new lease must not inherit a previous pending free")
    }

    func testAdditionalLeaseKeepsPendingReinitializationDeferred() {
        var state = WhisperContextLifecycleState()
        state.acquire()
        XCTAssertFalse(state.requestReinitialization())
        state.acquire()
        XCTAssertFalse(state.release())
        XCTAssertFalse(state.canReleaseForInactivity())
        XCTAssertTrue(state.pendingFree)
        XCTAssertTrue(state.release())
        XCTAssertTrue(state.canReleaseForInactivity())
        XCTAssertFalse(state.pendingFree)
    }

    func testUnmatchedReleaseDoesNotUnderflow() {
        var state = WhisperContextLifecycleState()
        XCTAssertFalse(state.release())
        XCTAssertEqual(state.activeUseCount, 0)
        state.acquire()
        XCTAssertFalse(state.release())
        XCTAssertFalse(state.release())
        XCTAssertEqual(state.activeUseCount, 0)
    }
}
