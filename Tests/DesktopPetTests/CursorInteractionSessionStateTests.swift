import XCTest
@testable import DesktopPetCore

final class CursorInteractionSessionStateTests: XCTestCase {
    func testPrepareStoresDistinctPairAsPending() {
        var state = CursorInteractionSessionState()

        XCTAssertTrue(state.prepare(preyID: "prey", interactionID: "cat"))

        XCTAssertEqual(state.phase, .pending)
        XCTAssertEqual(state.preyID, "prey")
        XCTAssertEqual(state.interactionID, "cat")
    }

    func testPrepareRejectsSameClipForBothRoles() {
        var state = CursorInteractionSessionState()

        XCTAssertFalse(state.prepare(preyID: "shared", interactionID: "shared"))

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.preyID)
        XCTAssertNil(state.interactionID)
    }

    func testActivateTransitionsPendingSessionOnly() {
        var state = CursorInteractionSessionState()

        XCTAssertFalse(state.activate())
        XCTAssertTrue(state.prepare(preyID: "prey", interactionID: "cat"))
        XCTAssertTrue(state.activate())
        XCTAssertFalse(state.activate())

        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.preyID, "prey")
        XCTAssertEqual(state.interactionID, "cat")
    }

    func testClearPendingReturnsPendingCleanupExactlyOnce() {
        var state = CursorInteractionSessionState()
        XCTAssertTrue(state.prepare(preyID: "prey", interactionID: "cat"))

        XCTAssertEqual(state.clear(), .pending)
        XCTAssertNil(state.clear())

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.preyID)
        XCTAssertNil(state.interactionID)
    }

    func testClearActiveReturnsActiveCleanupExactlyOnce() {
        var state = CursorInteractionSessionState()
        XCTAssertTrue(state.prepare(preyID: "prey", interactionID: "cat"))
        XCTAssertTrue(state.activate())

        XCTAssertEqual(state.clear(), .active)
        XCTAssertNil(state.clear())

        XCTAssertEqual(state.phase, .idle)
    }

    func testPrepareDoesNotReplacePendingOrActiveSession() {
        var state = CursorInteractionSessionState()
        XCTAssertTrue(state.prepare(preyID: "prey-1", interactionID: "cat-1"))
        XCTAssertFalse(state.prepare(preyID: "prey-2", interactionID: "cat-2"))
        XCTAssertTrue(state.activate())
        XCTAssertFalse(state.prepare(preyID: "prey-3", interactionID: "cat-3"))

        XCTAssertEqual(state.preyID, "prey-1")
        XCTAssertEqual(state.interactionID, "cat-1")
    }

    func testFrameFailureCancelsOnlyTheMatchingActiveOneShot() {
        var state = CursorInteractionSessionState()
        XCTAssertTrue(state.prepare(preyID: "prey", interactionID: "cat"))
        XCTAssertTrue(state.activate())

        XCTAssertTrue(state.shouldCancelForFrameFailure(
            clipID: "cat",
            currentClipID: "cat",
            isPlayingOneShot: true
        ))
        XCTAssertFalse(state.shouldCancelForFrameFailure(
            clipID: "ordinary",
            currentClipID: "ordinary",
            isPlayingOneShot: true
        ))
        XCTAssertFalse(state.shouldCancelForFrameFailure(
            clipID: "cat",
            currentClipID: "ordinary",
            isPlayingOneShot: true
        ))
        XCTAssertFalse(state.shouldCancelForFrameFailure(
            clipID: "cat",
            currentClipID: "cat",
            isPlayingOneShot: false
        ))
    }

    func testPendingSessionAlsoAcceptsMatchingOneShotFrameFailure() {
        var state = CursorInteractionSessionState()
        XCTAssertTrue(state.prepare(preyID: "prey", interactionID: "cat"))

        XCTAssertTrue(state.shouldCancelForFrameFailure(
            clipID: "cat",
            currentClipID: "cat",
            isPlayingOneShot: true
        ))
    }
}
