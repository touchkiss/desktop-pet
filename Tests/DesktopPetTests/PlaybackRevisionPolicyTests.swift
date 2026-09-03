import XCTest
@testable import DesktopPetCore

final class PlaybackRevisionPolicyTests: XCTestCase {
    func testAcceptsCallbackFromCurrentGeneration() {
        XCTAssertTrue(PlaybackRevisionPolicy.shouldAccept(expected: 12, current: 12))
    }

    func testRejectsCallbackFromStaleGeneration() {
        XCTAssertFalse(PlaybackRevisionPolicy.shouldAccept(expected: 11, current: 12))
    }
}
