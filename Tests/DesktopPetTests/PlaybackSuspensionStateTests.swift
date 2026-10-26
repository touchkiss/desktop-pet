import XCTest
@testable import DesktopPetCore

final class PlaybackSuspensionStateTests: XCTestCase {
    func testOverlappingReasonsAndRepeatedEventsAreIdempotent() {
        var state = PlaybackSuspensionState()
        XCTAssertTrue(state.setSleeping(true, reason: .system))
        XCTAssertFalse(state.setSleeping(true, reason: .system))
        XCTAssertFalse(state.setSleeping(true, reason: .display))
        XCTAssertFalse(state.setSleeping(false, reason: .system))
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.setSleeping(false, reason: .display))
        XCTAssertFalse(state.isSuspended)
        XCTAssertFalse(state.setSleeping(false, reason: .display))
    }
}
