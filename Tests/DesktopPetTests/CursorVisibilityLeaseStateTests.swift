import XCTest
@testable import DesktopPetCore

final class CursorVisibilityLeaseStateTests: XCTestCase {
    func testLeaseRequestsForegroundBeforeHidingAndRestoresFocusAfterward() {
        var lease = CursorVisibilityLeaseState()

        XCTAssertEqual(lease.start(), .requestForeground)
        XCTAssertNil(lease.start())
        XCTAssertEqual(lease.didBecomeActive(), .hideCursor)
        XCTAssertEqual(lease.didHideCursor(), .restorePreviousApplication)
        XCTAssertEqual(lease.stop(), .showCursor)
        XCTAssertNil(lease.stop())
    }

    func testLeaseStoppedBeforeCursorHideDoesNotRequestShow() {
        var lease = CursorVisibilityLeaseState()

        XCTAssertNil(lease.didBecomeActive())
        XCTAssertNil(lease.didHideCursor())
        XCTAssertNil(lease.stop())

        XCTAssertEqual(lease.start(), .requestForeground)
        XCTAssertNil(lease.stop())
        XCTAssertNil(lease.didBecomeActive())
        XCTAssertNil(lease.didHideCursor())
    }

    func testDuplicateActivationAndHideCallbacksAreIgnored() {
        var lease = CursorVisibilityLeaseState()

        XCTAssertEqual(lease.start(), .requestForeground)
        XCTAssertEqual(lease.didBecomeActive(), .hideCursor)
        XCTAssertNil(lease.didBecomeActive())
        XCTAssertEqual(lease.didHideCursor(), .restorePreviousApplication)
        XCTAssertNil(lease.didHideCursor())
        XCTAssertEqual(lease.stop(), .showCursor)
    }
}
