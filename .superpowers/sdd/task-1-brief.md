### Task 1: DesktopPetCore — types + frequency math

**Files:**
- Modify: `Package.swift`
- Create: `Sources/DesktopPetCore/TeleportTypes.swift`
- Create: `Sources/DesktopPetCore/TeleportMath.swift`
- Create: `Tests/DesktopPetTests/TeleportMathTests.swift`
- Modify: `Package.swift` executable target to depend on `DesktopPetCore`

**Interfaces:**
- Produces:
  - `enum TeleportEffectStyle: CaseIterable` — `portal`, `particles`, `warp`
  - `enum TeleportLandingMode` — `corner`, `cursorNudge`
  - `enum TeleportMath` with static helpers below

- [ ] **Step 1: Update Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DesktopPet", targets: ["DesktopPet"])
    ],
    targets: [
        .target(
            name: "DesktopPetCore",
            path: "Sources/DesktopPetCore"
        ),
        .executableTarget(
            name: "DesktopPet",
            dependencies: ["DesktopPetCore"],
            path: "Sources/DesktopPet",
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "DesktopPetTests",
            dependencies: ["DesktopPetCore"],
            path: "Tests/DesktopPetTests"
        )
    ]
)
```

- [ ] **Step 2: Write failing tests for frequency mapping**

Create `Tests/DesktopPetTests/TeleportMathTests.swift`:

```swift
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
```

- [ ] **Step 3: Run tests — expect FAIL**

Run: `cd /Users/liushiyou/Documents/macos/desktop-pet && swift test --filter TeleportMathTests`

Expected: compile failure or missing symbol `TeleportMath`

- [ ] **Step 4: Implement types + frequency math**

`Sources/DesktopPetCore/TeleportTypes.swift`:

```swift
public enum TeleportEffectStyle: String, CaseIterable, Sendable {
    case portal
    case particles
    case warp
}

public enum TeleportLandingMode: String, Sendable {
    case corner
    case cursorNudge
}
```

`Sources/DesktopPetCore/TeleportMath.swift`:

```swift
import Foundation
import CoreGraphics

public enum TeleportMath {
    public static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * clamp01(t)
    }

    /// Visible dwell before next vanish. Spec: lerp(60, 12, f).
    public static func dwellInterval(frequency: Double) -> Double {
        lerp(60, 12, frequency)
    }

    /// Hidden pause. Spec: lerp(2.0, 0.6, f).
    public static func hiddenDuration(frequency: Double) -> Double {
        lerp(2.0, 0.6, frequency)
    }

    /// `unitRandom` in 0...1 → ±15% around base.
    public static func jitteredInterval(base: Double, unitRandom: Double) -> Double {
        let t = clamp01(unitRandom)
        let factor = 0.85 + 0.30 * t
        return base * factor
    }

    public static func scheduleDwell(frequency: Double, unitRandom: Double) -> Double {
        jitteredInterval(base: dwellInterval(frequency: frequency), unitRandom: unitRandom)
    }

    public static func pickStyle(unitRandom: Double) -> TeleportEffectStyle {
        let styles = TeleportEffectStyle.allCases
        let idx = min(styles.count - 1, Int(clamp01(unitRandom) * Double(styles.count)))
        return styles[idx]
    }

    /// When nudgeEnabled, probability 1/4 → cursorNudge.
    public static func pickLandingMode(nudgeEnabled: Bool, unitRandom: Double) -> TeleportLandingMode {
        guard nudgeEnabled else { return .corner }
        return clamp01(unitRandom) < 0.25 ? .cursorNudge : .corner
    }
}
```

- [ ] **Step 5: Run tests — expect PASS**

Run: `swift test --filter TeleportMathTests`

Expected: all tests PASS

- [ ] **Step 6: Verify app still builds**

Run: `swift build`

Expected: success (DesktopPet links DesktopPetCore)

---

