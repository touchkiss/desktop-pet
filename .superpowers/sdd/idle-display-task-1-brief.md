### Task 1: Idle presentation policy

**Files:**
- Create: `Sources/DesktopPetCore/IdlePresentationPolicy.swift`
- Test: `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`

**Interfaces:**
- Consumes: no app-layer types.
- Produces: `IdlePresentationPhase`, `IdlePresentationPolicy.supportedIdleDelays`, `resolvedIdleDelay(storedValue:keyWasPresent:)`, `clampedManicScale(_:)`, `phase(idleSeconds:delay:)`, and `presentationMultiplier(manicScale:phase:)`.

- [ ] **Step 1: Write failing policy tests**

```swift
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
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter IdlePresentationPolicyTests`

Expected: compilation fails because `IdlePresentationPolicy` and `IdlePresentationPhase` do not exist.

- [ ] **Step 3: Implement the minimal pure policy**

```swift
import Foundation

public enum IdlePresentationPhase: Equatable, Sendable {
    case normal
    case manic
}

public enum IdlePresentationPolicy {
    public static let supportedIdleDelays: [TimeInterval] = [60, 180, 300, 600, 900, 1800]
    public static let defaultIdleDelay: TimeInterval = 300
    public static let minimumManicScale = 1.0
    public static let maximumManicScale = 3.0
    public static let defaultManicScale = 2.0

    public static func resolvedIdleDelay(
        storedValue: TimeInterval?,
        keyWasPresent: Bool
    ) -> TimeInterval? {
        guard keyWasPresent else { return defaultIdleDelay }
        guard let storedValue else { return nil }
        return supportedIdleDelays.contains(storedValue) ? storedValue : defaultIdleDelay
    }

    public static func clampedManicScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return defaultManicScale }
        return min(maximumManicScale, max(minimumManicScale, scale))
    }

    public static func phase(
        idleSeconds: TimeInterval,
        delay: TimeInterval?
    ) -> IdlePresentationPhase {
        guard idleSeconds.isFinite, idleSeconds >= 0, let delay else { return .normal }
        return idleSeconds >= delay ? .manic : .normal
    }

    public static func presentationMultiplier(
        manicScale: Double,
        phase: IdlePresentationPhase
    ) -> Double {
        phase == .manic ? clampedManicScale(manicScale) : 1
    }
}
```

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter IdlePresentationPolicyTests`

Expected: 3 tests pass.

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 5: Commit only the two new files**

```bash
git add Sources/DesktopPetCore/IdlePresentationPolicy.swift Tests/DesktopPetTests/IdlePresentationPolicyTests.swift
git diff --cached --check
git commit -m "[展示] 新增空闲魔性阶段策略"
```

