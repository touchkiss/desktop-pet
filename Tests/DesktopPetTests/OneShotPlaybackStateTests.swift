import XCTest
@testable import DesktopPetCore

final class OneShotPlaybackStateTests: XCTestCase {
    func testStartCapturesPreferredOrdinaryReturnID() {
        var state = OneShotPlaybackState()

        state.start(interactionID: "interaction", preferredReturnID: "ordinary")

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.interactionID, "interaction")
        XCTAssertEqual(state.preferredReturnID, "ordinary")
    }

    func testFinishReturnsCapturedOrdinaryClipAndIsHarmlessWhenRepeated() {
        var state = OneShotPlaybackState()
        state.start(interactionID: "interaction", preferredReturnID: "ordinary")

        XCTAssertEqual(
            state.finish(availableOrdinaryIDs: ["fallback", "ordinary"]),
            .play("ordinary")
        )
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.finish(availableOrdinaryIDs: ["fallback", "ordinary"]))
    }

    func testCancelReturnsTerminatedInteractionExactlyOnce() {
        var state = OneShotPlaybackState()
        state.start(interactionID: "interaction", preferredReturnID: "ordinary")

        XCTAssertEqual(state.cancel(), "interaction")
        XCTAssertNil(state.cancel())

        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.finish(availableOrdinaryIDs: ["ordinary"]))
    }

    func testFinishFallsBackToFirstAvailableOrdinaryClipWhenPreferredReturnIsInvalid() {
        var state = OneShotPlaybackState()
        state.start(interactionID: "interaction", preferredReturnID: "removed")

        XCTAssertEqual(
            state.finish(availableOrdinaryIDs: ["fallback", "another"]),
            .play("fallback")
        )
    }

    func testFinishStopsWhenNoOrdinaryFallbackExists() {
        var state = OneShotPlaybackState()
        state.start(interactionID: "interaction", preferredReturnID: "removed")

        XCTAssertEqual(state.finish(availableOrdinaryIDs: []), .stop)
    }

    func testCompletionResolutionRejectsANewSameIDSessionWithChangedRevision() {
        let completionRevision: UInt = 41
        let sameIDNewSessionRevision: UInt = 42

        XCTAssertTrue(OneShotPlaybackState.shouldApplyCompletionResolution(
            completionRevision: completionRevision,
            currentPlaybackRevision: completionRevision
        ))
        XCTAssertFalse(OneShotPlaybackState.shouldApplyCompletionResolution(
            completionRevision: completionRevision,
            currentPlaybackRevision: sameIDNewSessionRevision
        ))
    }
}
