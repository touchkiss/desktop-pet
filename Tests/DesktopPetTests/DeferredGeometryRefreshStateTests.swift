import XCTest
@testable import DesktopPetCore

final class DeferredGeometryRefreshStateTests: XCTestCase {
    func testRequestOutsideFreezeRefreshesImmediately() {
        var state = DeferredGeometryRefreshState()

        XCTAssertTrue(state.requestRefresh())
        XCTAssertFalse(state.endFreeze())
    }

    func testRequestDuringFreezeIsDeferredUntilFreezeEnds() {
        var state = DeferredGeometryRefreshState()

        state.beginFreeze()
        XCTAssertFalse(state.requestRefresh())
        XCTAssertTrue(state.endFreeze())
        XCTAssertFalse(state.endFreeze())
    }

    func testMultipleFrozenRequestsCoalesceIntoOneFinalRefresh() {
        var state = DeferredGeometryRefreshState()

        state.beginFreeze()
        XCTAssertFalse(state.requestRefresh())
        XCTAssertFalse(state.requestRefresh())
        XCTAssertTrue(state.endFreeze())
        XCTAssertFalse(state.endFreeze())
    }
}
