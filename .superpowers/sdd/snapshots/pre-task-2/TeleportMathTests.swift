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
}
