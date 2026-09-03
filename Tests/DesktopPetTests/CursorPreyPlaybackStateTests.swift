import XCTest
@testable import DesktopPetCore

final class CursorPreyPlaybackStateTests: XCTestCase {
    func testAdvanceLoopsFromLastFrameBackToFirst() {
        var state = CursorPreyPlaybackState()

        XCTAssertTrue(state.start(frameCount: 3))
        XCTAssertEqual(state.currentFrame, 1)
        XCTAssertEqual(state.advance(), 2)
        XCTAssertEqual(state.advance(), 3)
        XCTAssertEqual(state.advance(), 1)
    }

    func testStopMakesAdvanceHarmlessAndAllowsANewSession() {
        var state = CursorPreyPlaybackState()

        XCTAssertTrue(state.start(frameCount: 2))
        state.stop()
        state.stop()
        XCTAssertNil(state.advance())

        XCTAssertTrue(state.start(frameCount: 1))
        XCTAssertEqual(state.currentFrame, 1)
        XCTAssertEqual(state.advance(), 1)
    }

    func testStartRejectsAnEmptyFrameSequence() {
        var state = CursorPreyPlaybackState()

        XCTAssertFalse(state.start(frameCount: 0))
        XCTAssertNil(state.currentFrame)
        XCTAssertNil(state.advance())
    }

    func testElapsedAdvanceSkipsFramesAndWrapsDeterministically() {
        var state = CursorPreyPlaybackState()

        XCTAssertTrue(state.start(frameCount: 4))
        XCTAssertEqual(state.advance(elapsed: 0.75, fps: 4), 4)
        XCTAssertEqual(state.advance(elapsed: 0.5, fps: 4), 2)
    }

    func testElapsedAdvanceCarriesPartialFrameTimeToTheNextTick() {
        var state = CursorPreyPlaybackState()

        XCTAssertTrue(state.start(frameCount: 3))
        XCTAssertEqual(state.advance(elapsed: 0.04, fps: 24), 1)
        XCTAssertEqual(state.advance(elapsed: 0.01, fps: 24), 2)
    }
}
