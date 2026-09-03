import XCTest
@testable import DesktopPetCore

final class CursorInteractionPolicyTests: XCTestCase {
    func testPreySizeBoundsAreInclusive() {
        XCTAssertEqual(CursorInteractionPolicy.minimumPreyDisplaySize, 16)
        XCTAssertEqual(CursorInteractionPolicy.maximumPreyDisplaySize, 128)
        XCTAssertEqual(CursorInteractionPolicy.clampedPreyDisplaySize(16), 16)
        XCTAssertEqual(CursorInteractionPolicy.clampedPreyDisplaySize(128), 128)
    }

    func testPreySizeIsClampedToSupportedRange() {
        XCTAssertEqual(CursorInteractionPolicy.clampedPreyDisplaySize(-10), 16)
        XCTAssertEqual(CursorInteractionPolicy.clampedPreyDisplaySize(200), 128)
    }

    func testDefaultPreySizeIs48Points() {
        XCTAssertEqual(CursorInteractionPolicy.defaultPreyDisplaySize, 48)
    }

    func testInteractionRequiresAutonomousCursorNudgeAndBothCandidates() {
        XCTAssertTrue(CursorInteractionPolicy.isInteractionEligible(
            isAutonomous: true,
            landingMode: .cursorNudge,
            hasPreyCandidate: true,
            hasInteractionCandidate: true
        ))
        XCTAssertFalse(CursorInteractionPolicy.isInteractionEligible(
            isAutonomous: false,
            landingMode: .cursorNudge,
            hasPreyCandidate: true,
            hasInteractionCandidate: true
        ))
        XCTAssertFalse(CursorInteractionPolicy.isInteractionEligible(
            isAutonomous: true,
            landingMode: .corner,
            hasPreyCandidate: true,
            hasInteractionCandidate: true
        ))
        XCTAssertFalse(CursorInteractionPolicy.isInteractionEligible(
            isAutonomous: true,
            landingMode: .cursorNudge,
            hasPreyCandidate: false,
            hasInteractionCandidate: true
        ))
        XCTAssertFalse(CursorInteractionPolicy.isInteractionEligible(
            isAutonomous: true,
            landingMode: .cursorNudge,
            hasPreyCandidate: true,
            hasInteractionCandidate: false
        ))
    }
}
