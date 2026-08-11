import XCTest
@testable import DesktopPetCore

final class TeleportMathTests: XCTestCase {
    func testDwellIntervalEndpoints() {
        XCTAssertEqual(TeleportMath.dwellInterval(frequency: 0), 60, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.dwellInterval(frequency: 1), 12, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.dwellInterval(frequency: 0.5), 36, accuracy: 0.001)
    }

    func testDwellIntervalClamps() {
        XCTAssertEqual(TeleportMath.dwellInterval(frequency: -1), 60, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.dwellInterval(frequency: 2), 12, accuracy: 0.001)
    }

    func testHiddenDurationEndpoints() {
        XCTAssertEqual(TeleportMath.hiddenDuration(frequency: 0), 2.0, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.hiddenDuration(frequency: 1), 0.6, accuracy: 0.001)
    }

    func testJitterStaysWithin15Percent() {
        let base = 36.0
        for _ in 0..<50 {
            let v = TeleportMath.jitteredInterval(base: base, unitRandom: Double.random(in: 0...1))
            XCTAssertGreaterThanOrEqual(v, base * 0.85)
            XCTAssertLessThanOrEqual(v, base * 1.15)
        }
    }

    func testClipEndTeleportChanceEndpoints() {
        XCTAssertEqual(TeleportMath.clipEndTeleportChance(frequency: 0), 0.25, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.clipEndTeleportChance(frequency: 1), 1.0, accuracy: 0.001)
        XCTAssertTrue(TeleportMath.shouldTeleportAtClipEnd(frequency: 1, unitRandom: 0.99))
        XCTAssertFalse(TeleportMath.shouldTeleportAtClipEnd(frequency: 0, unitRandom: 0.5))
    }

    func testCornerRegionsCountAndContainment() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let regions = TeleportMath.cornerRegions(in: frame)
        XCTAssertEqual(regions.count, 4)
        for r in regions {
            XCTAssertTrue(frame.contains(r))
        }
    }

    func testRandomOriginKeepsPetInsideVisible() {
        let visible = CGRect(x: 100, y: 50, width: 800, height: 600)
        let region = CGRect(x: 100, y: 50, width: 160, height: 120)
        let size = CGSize(width: 80, height: 80)
        let origin = TeleportMath.randomOrigin(
            in: region,
            petSize: size,
            visibleFrame: visible,
            unitRandomX: 1,
            unitRandomY: 1
        )
        let pet = CGRect(origin: origin, size: size)
        XCTAssertTrue(visible.contains(pet))
    }

    func testFarEnoughUsesDiagonal() {
        let size = CGSize(width: 100, height: 100)
        let diagonal = hypot(100.0, 100.0)
        let minDist = 1.5 * diagonal
        XCTAssertFalse(TeleportMath.isFarEnough(
            from: .zero,
            to: CGPoint(x: minDist - 1, y: 0),
            petSize: size
        ))
        XCTAssertTrue(TeleportMath.isFarEnough(
            from: .zero,
            to: CGPoint(x: minDist + 1, y: 0),
            petSize: size
        ))
    }

    func testCursorNudgeReturnsNilWhenTooCloseAfterClamp() {
        // Tiny visible frame forces clamp onto cursor → nil (caller falls back to corner).
        let visible = CGRect(x: 0, y: 0, width: 120, height: 120)
        let pet = CGSize(width: 100, height: 100)
        let cursor = CGPoint(x: 60, y: 60)
        let result = TeleportMath.cursorNudgeOrigin(
            cursor: cursor,
            petSize: pet,
            visibleFrame: visible,
            angleUnit: 0,
            radiusUnit: 0
        )
        XCTAssertNil(result)
    }

    func testCursorNudgeKeepsDistanceWhenRoomExists() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let pet = CGSize(width: 80, height: 80)
        let cursor = CGPoint(x: 1000, y: 600)
        let origin = TeleportMath.cursorNudgeOrigin(
            cursor: cursor,
            petSize: pet,
            visibleFrame: visible,
            angleUnit: 0,
            radiusUnit: 0.5
        )
        XCTAssertNotNil(origin)
        let center = CGPoint(x: origin!.x + 40, y: origin!.y + 40)
        let dist = hypot(center.x - cursor.x, center.y - cursor.y)
        XCTAssertGreaterThanOrEqual(dist, 80)
    }

    func testPickCornerOriginReturnsFarEnoughCandidate() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let screens = [TeleportScreenBox(visibleFrame: visible)]
        let pet = CGSize(width: 80, height: 80)
        let current = CGPoint(x: 100, y: 100)
        // screen 0, region 3 (bottom-trailing), min corner
        let result = TeleportMath.pickCornerOrigin(
            screens: screens,
            petSize: pet,
            currentOrigin: current,
            unitRandoms: [0, 0.75, 0, 0],
            maxAttempts: 12
        )
        XCTAssertTrue(TeleportMath.isFarEnough(from: current, to: result, petSize: pet))
    }

    func testPickCornerOriginFallsBackToFarthestAfterMaxAttempts() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let screens = [TeleportScreenBox(visibleFrame: visible)]
        let pet = CGSize(width: 80, height: 80)
        let current = CGPoint(x: 100, y: 650)
        // Three attempts in top-leading region (index 0); none far enough.
        let randoms: [Double] = [
            0, 0, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
        let result = TeleportMath.pickCornerOrigin(
            screens: screens,
            petSize: pet,
            currentOrigin: current,
            unitRandoms: randoms,
            maxAttempts: 3
        )
        XCTAssertFalse(TeleportMath.isFarEnough(from: current, to: result, petSize: pet))
        let regions = TeleportMath.cornerRegions(in: visible)
        let region = regions[0]
        let candidates = [
            TeleportMath.randomOrigin(in: region, petSize: pet, visibleFrame: visible, unitRandomX: 0, unitRandomY: 0),
            TeleportMath.randomOrigin(in: region, petSize: pet, visibleFrame: visible, unitRandomX: 1, unitRandomY: 0),
            TeleportMath.randomOrigin(in: region, petSize: pet, visibleFrame: visible, unitRandomX: 0, unitRandomY: 1)
        ]
        let currentCenter = TeleportMath.petCenter(origin: current, size: pet)
        func dist(_ o: CGPoint) -> CGFloat {
            let c = TeleportMath.petCenter(origin: o, size: pet)
            return hypot(c.x - currentCenter.x, c.y - currentCenter.y)
        }
        let expected = candidates.max(by: { dist($0) < dist($1) })!
        XCTAssertEqual(result.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(result.y, expected.y, accuracy: 0.001)
    }

    func testPickCornerOriginEmptyScreensReturnsCurrentOrigin() {
        let pet = CGSize(width: 80, height: 80)
        let current = CGPoint(x: 200, y: 300)
        let result = TeleportMath.pickCornerOrigin(
            screens: [],
            petSize: pet,
            currentOrigin: current,
            unitRandoms: [0.5],
            maxAttempts: 12
        )
        XCTAssertEqual(result, current)
    }

    func testPickCornerOriginUnitRandomOneSelectsLastIndex() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let screens = [
            TeleportScreenBox(visibleFrame: visible),
            TeleportScreenBox(visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 800))
        ]
        let pet = CGSize(width: 80, height: 80)
        let current = CGPoint(x: 5000, y: 5000)
        // unitRandom 1.0 → last screen (index 1) and last region (index 3)
        let result = TeleportMath.pickCornerOrigin(
            screens: screens,
            petSize: pet,
            currentOrigin: current,
            unitRandoms: [1, 1, 0, 0],
            maxAttempts: 1
        )
        let secondScreen = screens[1].visibleFrame
        let lastRegion = TeleportMath.cornerRegions(in: secondScreen)[3]
        let expected = TeleportMath.randomOrigin(
            in: lastRegion,
            petSize: pet,
            visibleFrame: secondScreen,
            unitRandomX: 0,
            unitRandomY: 0
        )
        XCTAssertEqual(result.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(result.y, expected.y, accuracy: 0.001)
    }
}
