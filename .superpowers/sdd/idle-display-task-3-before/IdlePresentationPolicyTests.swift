import XCTest
@testable import DesktopPetCore

final class IdlePresentationPolicyTests: XCTestCase {
    func testSupportedDelaysAndLegacyDefaultAreExact() {
        XCTAssertEqual(IdlePresentationPolicy.supportedIdleDelays, [60, 180, 300, 600, 900, 1800])
        XCTAssertEqual(
            IdlePresentationPolicy.resolvedIdleDelay(storedValue: nil, keyWasPresent: false),
            300
        )
        XCTAssertNil(IdlePresentationPolicy.resolvedIdleDelay(storedValue: nil, keyWasPresent: true))
        XCTAssertEqual(
            IdlePresentationPolicy.resolvedIdleDelay(storedValue: 123, keyWasPresent: true),
            300
        )
    }

    func testPhaseUsesThresholdAndTreatsInvalidIdleAsZero() {
        XCTAssertEqual(IdlePresentationPolicy.phase(idleSeconds: 299.9, delay: 300), .normal)
        XCTAssertEqual(IdlePresentationPolicy.phase(idleSeconds: 300, delay: 300), .manic)
        XCTAssertEqual(IdlePresentationPolicy.phase(idleSeconds: 900, delay: nil), .normal)
        XCTAssertEqual(IdlePresentationPolicy.phase(idleSeconds: .nan, delay: 300), .normal)
        XCTAssertEqual(IdlePresentationPolicy.phase(idleSeconds: -1, delay: 300), .normal)
    }

    func testManicScaleClampsAndProducesPresentationMultiplier() {
        XCTAssertEqual(IdlePresentationPolicy.clampedManicScale(.nan), 2)
        XCTAssertEqual(IdlePresentationPolicy.clampedManicScale(0.5), 1)
        XCTAssertEqual(IdlePresentationPolicy.clampedManicScale(4), 3)
        XCTAssertEqual(
            IdlePresentationPolicy.presentationMultiplier(manicScale: 2.5, phase: .normal),
            1
        )
        XCTAssertEqual(
            IdlePresentationPolicy.presentationMultiplier(manicScale: 2.5, phase: .manic),
            2.5
        )
    }
}
