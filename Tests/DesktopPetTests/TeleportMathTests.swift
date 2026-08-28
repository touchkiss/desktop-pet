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
        XCTAssertEqual(TeleportMath.clipEndTeleportChance(frequency: 0), 0.05, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.clipEndTeleportChance(frequency: 1), 0.20, accuracy: 0.001)
        XCTAssertTrue(TeleportMath.shouldTeleportAtClipEnd(frequency: 1, unitRandom: 0.199))
        XCTAssertFalse(TeleportMath.shouldTeleportAtClipEnd(frequency: 1, unitRandom: 0.20))
        XCTAssertFalse(TeleportMath.shouldTeleportAtClipEnd(frequency: 0, unitRandom: 0.05))
    }

    func testCursorNudgeLandingChanceIsFivePercent() {
        XCTAssertEqual(
            TeleportMath.pickLandingMode(nudgeEnabled: true, unitRandom: 0.049),
            .cursorNudge
        )
        XCTAssertEqual(
            TeleportMath.pickLandingMode(nudgeEnabled: true, unitRandom: 0.05),
            .corner
        )
        XCTAssertEqual(
            TeleportMath.pickLandingMode(nudgeEnabled: false, unitRandom: 0),
            .corner
        )
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

    func testShouldShowTravelStreakUsesChance() {
        XCTAssertTrue(TeleportMath.shouldShowTravelStreak(unitRandom: 0))
        XCTAssertTrue(TeleportMath.shouldShowTravelStreak(
            unitRandom: TeleportMath.travelStreakChance - 0.01
        ))
        XCTAssertFalse(TeleportMath.shouldShowTravelStreak(
            unitRandom: TeleportMath.travelStreakChance
        ))
        XCTAssertFalse(TeleportMath.shouldShowTravelStreak(unitRandom: 1))
    }

    func testTravelDurationClamps() {
        XCTAssertEqual(TeleportMath.travelDuration(distance: 0), 0.3, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.travelDuration(distance: 100), 0.3, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.travelDuration(distance: 1200), 0.5, accuracy: 0.001)
        XCTAssertEqual(TeleportMath.travelDuration(distance: 10000), 0.85, accuracy: 0.001)
    }

    func testTravelWaypointsCountAlternationAndOrder() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 1000, y: 0)
        // turns=3 (0.9), side seed 0 → first swing +y; jitter/amp neutral.
        let randoms: [Double] = [0.9, 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]
        let points = TeleportMath.travelWaypoints(from: from, to: to, unitRandoms: randoms)
        XCTAssertEqual(points.count, 3)
        XCTAssertGreaterThan(points[0].y, 0)
        XCTAssertLessThan(points[1].y, 0)
        XCTAssertGreaterThan(points[2].y, 0)
        XCTAssertTrue(points[0].x > 0 && points[2].x < 1000)
        XCTAssertTrue(points[0].x < points[1].x && points[1].x < points[2].x)
    }

    func testTravelWaypointsDegenerateChordIsEmpty() {
        let p = CGPoint(x: 5, y: 5)
        XCTAssertTrue(TeleportMath.travelWaypoints(from: p, to: p, unitRandoms: [0.5]).isEmpty)
    }

    func testTravelPathLengthAtLeastChord() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 800, y: 600)
        let randoms: [Double] = [0.6, 0.2, 0.5, 0.8, 0.5, 0.9]
        let waypoints = TeleportMath.travelWaypoints(from: from, to: to, unitRandoms: randoms)
        let length = TeleportMath.travelPathLength(from: from, to: to, waypoints: waypoints)
        XCTAssertGreaterThanOrEqual(length, 1000 - 0.001)
        XCTAssertEqual(
            TeleportMath.travelPathLength(from: from, to: to, waypoints: []),
            1000,
            accuracy: 0.001
        )
    }

    func testStreakAllowedRequiresBothEnds() {
        XCTAssertTrue(TeleportMath.streakAllowed(vanishStyle: .blink, appearStyle: .blink))
        XCTAssertFalse(TeleportMath.streakAllowed(vanishStyle: .blink, appearStyle: .particles))
        XCTAssertFalse(TeleportMath.streakAllowed(vanishStyle: .develop, appearStyle: .blink))
    }

    func testSwarmIsIntegrated() {
        XCTAssertFalse(TeleportMath.styleSupportsStreak(.swarm))
        let pair = TeleportMath.resolveStylePair(vanishDraw: .blink, appearDraw: .swarm)
        XCTAssertEqual(pair.vanish, .swarm)
        XCTAssertEqual(pair.appear, .swarm)
        // Swarm outranks ink when both are drawn.
        let mixed = TeleportMath.resolveStylePair(vanishDraw: .ink, appearDraw: .swarm)
        XCTAssertEqual(mixed.vanish, .swarm)
        // And it never stacks another bridge on top.
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .swarm, appearStyle: .swarm, unitRandom: 0.1),
            TravelMiddle.none
        )
    }

    func testInkComesAsAPair() {
        let inkFirst = TeleportMath.resolveStylePair(vanishDraw: .ink, appearDraw: .beam)
        XCTAssertEqual(inkFirst.vanish, .ink)
        XCTAssertEqual(inkFirst.appear, .ink)
        let inkSecond = TeleportMath.resolveStylePair(vanishDraw: .pixel, appearDraw: .ink)
        XCTAssertEqual(inkSecond.vanish, .ink)
        XCTAssertEqual(inkSecond.appear, .ink)
        let untouched = TeleportMath.resolveStylePair(vanishDraw: .blink, appearDraw: .scanline)
        XCTAssertEqual(untouched.vanish, .blink)
        XCTAssertEqual(untouched.appear, .scanline)
    }

    func testInkPairPrefersInkBridges() {
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .ink, appearStyle: .ink, unitRandom: 0.3),
            .comet
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .ink, appearStyle: .ink, unitRandom: 0.7),
            .vortex
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .ink, appearStyle: .ink, unitRandom: 0.9),
            .shadowHops
        )
    }

    func testStyleSupportsStreakBinding() {
        XCTAssertTrue(TeleportMath.styleSupportsStreak(.blink))
        XCTAssertTrue(TeleportMath.styleSupportsStreak(.smear))
        XCTAssertFalse(TeleportMath.styleSupportsStreak(.particles))
        XCTAssertFalse(TeleportMath.styleSupportsStreak(.beam))
        XCTAssertFalse(TeleportMath.styleSupportsStreak(.pixel))
        XCTAssertTrue(TeleportMath.styleSupportsStreak(.ink))
        XCTAssertFalse(TeleportMath.styleSupportsStreak(.scanline))
        XCTAssertFalse(TeleportMath.styleSupportsStreak(.develop))
    }

    func testPickTravelMiddleRules() {
        // Blink pairs favour shadow hops.
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .blink, appearStyle: .blink, unitRandom: 0.3),
            .shadowHops
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .blink, appearStyle: .blink, unitRandom: 0.7),
            .comet
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .blink, appearStyle: .blink, unitRandom: 0.9),
            .vortex
        )
        // Smear is move-style: pairs draw across the whole bridge family.
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .smear, appearStyle: .blink, unitRandom: 0.2),
            .comet
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .smear, appearStyle: .smear, unitRandom: 0.5),
            .cloud
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .smear, appearStyle: .blink, unitRandom: 0.7),
            .vortex
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .smear, appearStyle: .develop, unitRandom: 0.2),
            .none
        )
        // Wipe / in-place ends go bridgeless.
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .particles, appearStyle: .blink, unitRandom: 0.1),
            .none
        )
        XCTAssertEqual(
            TeleportMath.pickTravelMiddle(vanishStyle: .pixel, appearStyle: .pixel, unitRandom: 0.1),
            .none
        )
    }

    func testPointAlongPolyline() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 100, y: 0)
        let mid = TeleportMath.pointAlongPolyline(from: from, to: to, waypoints: [], fraction: 0.5)
        XCTAssertEqual(mid.x, 50, accuracy: 0.001)
        XCTAssertEqual(mid.y, 0, accuracy: 0.001)
        // With a right-angle waypoint the halfway point sits at the corner.
        let corner = TeleportMath.pointAlongPolyline(
            from: from,
            to: CGPoint(x: 100, y: 100),
            waypoints: [CGPoint(x: 100, y: 0)],
            fraction: 0.5
        )
        XCTAssertEqual(corner.x, 100, accuracy: 0.001)
        XCTAssertEqual(corner.y, 0, accuracy: 0.001)
        XCTAssertEqual(
            TeleportMath.pointAlongPolyline(from: from, to: to, waypoints: [], fraction: 0).x,
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TeleportMath.pointAlongPolyline(from: from, to: to, waypoints: [], fraction: 1).x,
            100,
            accuracy: 0.001
        )
    }

    func testTravelControlPointPerpendicularOffset() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 1000, y: 0)
        // Horizontal chord → control point offsets vertically from midpoint.
        let low = TeleportMath.travelControlPoint(from: from, to: to, bulgeUnit: 0, sideUnit: 0)
        XCTAssertEqual(low.x, 500, accuracy: 0.001)
        XCTAssertEqual(abs(low.y), 120, accuracy: 0.001)
        let high = TeleportMath.travelControlPoint(from: from, to: to, bulgeUnit: 1, sideUnit: 0)
        XCTAssertEqual(abs(high.y), 200, accuracy: 0.001)
        // sideUnit flips the sign of the offset.
        let a = TeleportMath.travelControlPoint(from: from, to: to, bulgeUnit: 0.5, sideUnit: 0)
        let b = TeleportMath.travelControlPoint(from: from, to: to, bulgeUnit: 0.5, sideUnit: 1)
        XCTAssertEqual(a.y, -b.y, accuracy: 0.001)
    }

    func testTravelControlPointDegenerateChordReturnsMidpoint() {
        let p = CGPoint(x: 42, y: 24)
        let c = TeleportMath.travelControlPoint(from: p, to: p, bulgeUnit: 1, sideUnit: 0)
        XCTAssertEqual(c.x, p.x, accuracy: 0.001)
        XCTAssertEqual(c.y, p.y, accuracy: 0.001)
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
