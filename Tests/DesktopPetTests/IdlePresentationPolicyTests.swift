import XCTest
@testable import DesktopPetCore

final class IdlePresentationPolicyTests: XCTestCase {
    func testHIDIdleTimeQueryUsesAnyInputEventSentinel() {
        var queriedEventType: UInt32?
        let seconds = HIDIdleTimeQuery.secondsSinceAnyInput { eventType in
            queriedEventType = eventType
            return 42
        }

        XCTAssertEqual(seconds, 42)
        XCTAssertEqual(queriedEventType, UInt32.max)
    }

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

    func testPersistedManicScaleUsesSafeDefaultAndBounds() {
        XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(nil), 2)
        XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(.nan), 2)
        XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(0.5), 1)
        XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(4), 3)
    }

    func testPersistedIdleDelayDecodesExplicitNullAsNil() throws {
        let decoded = try JSONDecoder().decode(
            PersistedIdleDelayFixture.self,
            from: Data(#"{"manicIdleDelay":null}"#.utf8)
        )

        XCTAssertNil(decoded.manicIdleDelay)
    }

    func testPersistedIdleDelayEncodesNilWithExplicitNullKey() throws {
        let encoded = try JSONEncoder().encode(PersistedIdleDelayFixture(manicIdleDelay: nil))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertTrue(json.keys.contains("manicIdleDelay"))
        XCTAssertTrue(json["manicIdleDelay"] is NSNull)
    }

    func testPersistedIdleDelayRoundTripKeepsClosedState() throws {
        let encoded = try JSONEncoder().encode(PersistedIdleDelayFixture(manicIdleDelay: nil))
        let decoded = try JSONDecoder().decode(PersistedIdleDelayFixture.self, from: encoded)

        XCTAssertNil(decoded.manicIdleDelay)
    }
}

private struct PersistedIdleDelayFixture: Codable {
    private var manicIdleDelayStorage: PersistedIdleDelay

    var manicIdleDelay: TimeInterval? {
        get { manicIdleDelayStorage.value }
        set { manicIdleDelayStorage = PersistedIdleDelay(value: newValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case manicIdleDelayStorage = "manicIdleDelay"
    }

    init(manicIdleDelay: TimeInterval?) {
        manicIdleDelayStorage = PersistedIdleDelay(value: manicIdleDelay)
    }
}
