# Random Teleport Effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional sci-fi hide/appear teleport for the desktop pet, with corner-biased multi-screen landings, random Core Animation styles, and a lower-frequency cursor-nudge reminder bubble with editable copy.

**Architecture:** Persist settings on `LibraryState`. Pure timing/landing math lives in a small `DesktopPetCore` library (unit-tested). `TeleportController` owns the state machine and timer. `TeleportEffectRenderer` draws portal/particles/warp on a `PetContentView` overlay. `AppDelegate` wires lifecycle; drag on the pet cancels in-flight teleports.

**Tech Stack:** Swift 5.9, macOS 13+, AppKit, Core Animation (`CAShapeLayer`, `CAEmitterLayer`), Swift Package Manager.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-random-teleport-effects-design.md`
- Platform: macOS 13+ (existing `Package.swift`)
- No Metal / SpriteKit / extra effect windows
- Frequency: `interval = lerp(60, 12, f)` s with ±15% jitter; `hidden = lerp(2.0, 0.6, f)` s
- Styles: random among `portal` | `particles` | `warp` (same style for vanish+appear)
- Cursor nudge: 1/4 probability when enabled; bubble from `reminderMessages`
- Drag cancel: immediate; window origin only moves after vanish completes
- Do not commit unless the user asks (user rule overrides plan commit steps — skip git commit steps unless explicitly requested)

---

## File structure

| File | Role |
|------|------|
| `Package.swift` | Add `DesktopPetCore` library + `DesktopPetTests` |
| `Sources/DesktopPetCore/TeleportMath.swift` | Interval, landing, style/mode picks (pure) |
| `Sources/DesktopPetCore/TeleportTypes.swift` | Shared enums used by math + app |
| `Tests/DesktopPetTests/TeleportMathTests.swift` | Unit tests for math |
| `Sources/DesktopPet/Models.swift` | New `LibraryState` fields |
| `Sources/DesktopPet/LibraryWindowController.swift` | Settings UI + message editor |
| `Sources/DesktopPet/PetWindowController.swift` | Drag cancel, overlay host, move/persist API |
| `Sources/DesktopPet/TeleportEffectRenderer.swift` | CA effects + reminder bubble |
| `Sources/DesktopPet/TeleportController.swift` | Timer + state machine |
| `Sources/DesktopPet/AppDelegate.swift` | Construct, pause on menu hide |

---

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

### Task 2: Landing geometry math

**Files:**
- Modify: `Sources/DesktopPetCore/TeleportMath.swift`
- Modify: `Tests/DesktopPetTests/TeleportMathTests.swift`

**Interfaces:**
- Consumes: `TeleportMath` from Task 1
- Produces:
  - `struct TeleportScreenBox: Equatable` — `visibleFrame: CGRect`
  - `static func cornerRegions(in visibleFrame: CGRect) -> [CGRect]`
  - `static func randomOrigin(in region: CGRect, petSize: CGSize, visibleFrame: CGRect, unitRandomX: Double, unitRandomY: Double) -> CGPoint`
  - `static func isFarEnough(from: CGPoint, to: CGPoint, petSize: CGSize) -> Bool`
  - `static func cursorNudgeOrigin(cursor: CGPoint, petSize: CGSize, visibleFrame: CGRect, angleUnit: Double, radiusUnit: Double) -> CGPoint?`
  - `static func pickCornerOrigin(screens: [TeleportScreenBox], petSize: CGSize, currentOrigin: CGPoint, unitRandoms: [Double], maxAttempts: Int) -> CGPoint`

- [ ] **Step 1: Write failing landing tests**

Append to `TeleportMathTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `swift test --filter TeleportMathTests`

Expected: missing landing symbols

- [ ] **Step 3: Implement landing helpers**

Append to `TeleportMath.swift`:

```swift
public struct TeleportScreenBox: Equatable, Sendable {
    public var visibleFrame: CGRect
    public init(visibleFrame: CGRect) { self.visibleFrame = visibleFrame }
}

extension TeleportMath {
    /// Four corner bands (~8%–20% of edges). Use 20% width/height squares at each corner.
    public static func cornerRegions(in visibleFrame: CGRect) -> [CGRect] {
        let w = visibleFrame.width * 0.20
        let h = visibleFrame.height * 0.20
        let f = visibleFrame
        return [
            CGRect(x: f.minX, y: f.maxY - h, width: w, height: h), // top-leading
            CGRect(x: f.maxX - w, y: f.maxY - h, width: w, height: h), // top-trailing
            CGRect(x: f.minX, y: f.minY, width: w, height: h), // bottom-leading
            CGRect(x: f.maxX - w, y: f.minY, width: w, height: h) // bottom-trailing
        ]
    }

    public static func clampOrigin(_ origin: CGPoint, petSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let maxX = visibleFrame.maxX - petSize.width
        let maxY = visibleFrame.maxY - petSize.height
        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX)),
            y: min(max(origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
        )
    }

    public static func randomOrigin(
        in region: CGRect,
        petSize: CGSize,
        visibleFrame: CGRect,
        unitRandomX: Double,
        unitRandomY: Double
    ) -> CGPoint {
        let usable = CGRect(
            x: region.minX,
            y: region.minY,
            width: max(0, region.width - petSize.width),
            height: max(0, region.height - petSize.height)
        )
        let origin = CGPoint(
            x: usable.minX + usable.width * CGFloat(clamp01(unitRandomX)),
            y: usable.minY + usable.height * CGFloat(clamp01(unitRandomY))
        )
        return clampOrigin(origin, petSize: petSize, visibleFrame: visibleFrame)
    }

    public static func petCenter(origin: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    public static func isFarEnough(from: CGPoint, to: CGPoint, petSize: CGSize) -> Bool {
        let minDist = 1.5 * hypot(petSize.width, petSize.height)
        let a = petCenter(origin: from, size: petSize)
        let b = petCenter(origin: to, size: petSize)
        return hypot(a.x - b.x, a.y - b.y) >= minDist
    }

    /// Ring radius lerp(120, 200, radiusUnit). Returns nil if center distance to cursor < 80 after clamp.
    public static func cursorNudgeOrigin(
        cursor: CGPoint,
        petSize: CGSize,
        visibleFrame: CGRect,
        angleUnit: Double,
        radiusUnit: Double
    ) -> CGPoint? {
        let angle = clamp01(angleUnit) * 2 * Double.pi
        let radius = lerp(120, 200, radiusUnit)
        let center = CGPoint(
            x: cursor.x + CGFloat(cos(angle) * radius),
            y: cursor.y + CGFloat(sin(angle) * radius)
        )
        let rawOrigin = CGPoint(x: center.x - petSize.width / 2, y: center.y - petSize.height / 2)
        let origin = clampOrigin(rawOrigin, petSize: petSize, visibleFrame: visibleFrame)
        let petC = petCenter(origin: origin, size: petSize)
        let dist = hypot(petC.x - cursor.x, petC.y - cursor.y)
        if dist < 80 { return nil }
        return origin
    }

    public static func pickCornerOrigin(
        screens: [TeleportScreenBox],
        petSize: CGSize,
        currentOrigin: CGPoint,
        unitRandoms: [Double],
        maxAttempts: Int = 12
    ) -> CGPoint {
        precondition(!screens.isEmpty)
        var best = clampOrigin(currentOrigin, petSize: petSize, visibleFrame: screens[0].visibleFrame)
        var ri = 0
        func next() -> Double {
            defer { ri += 1 }
            if ri < unitRandoms.count { return unitRandoms[ri] }
            return 0.5
        }
        for _ in 0..<maxAttempts {
            let screen = screens[Int(clamp01(next()) * Double(screens.count)) % screens.count]
            let regions = cornerRegions(in: screen.visibleFrame)
            let region = regions[Int(clamp01(next()) * Double(regions.count)) % regions.count]
            let candidate = randomOrigin(
                in: region,
                petSize: petSize,
                visibleFrame: screen.visibleFrame,
                unitRandomX: next(),
                unitRandomY: next()
            )
            best = candidate
            if isFarEnough(from: currentOrigin, to: candidate, petSize: petSize) {
                return candidate
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter TeleportMathTests`

Expected: PASS (adjust `testCursorNudgeReturnsNilWhenTooCloseAfterClamp` geometry if a false positive appears — keep the <80 rule)

---

### Task 3: LibraryState settings fields

**Files:**
- Modify: `Sources/DesktopPet/Models.swift`
- Create: `Tests/DesktopPetTests/LibraryStateTeleportDecodingTests.swift` — **only if** decode helpers are moved to Core; otherwise verify with a small decode test by duplicating JSON round-trip in a new Core-free approach:

Because `LibraryState` lives in the executable module (not importable by tests), verify decode via a **manual** build + a focused runtime assert in DEBUG, **or** move only the default constants to Core.

**Preferred:** keep fields in `Models.swift`; add decode defaults; cover with manual check in Step 4. Pure defaults constant in Core for reuse:

- Modify: `Sources/DesktopPetCore/TeleportMath.swift` — add `public static let defaultReminderMessages`

**Interfaces:**
- Produces on `LibraryState`: `teleportEnabled`, `teleportFrequency`, `cursorNudgeEnabled`, `reminderMessages`
- `LibraryState.empty` and `init(from:)` use defaults when keys missing

- [ ] **Step 1: Add default messages constant to Core**

```swift
// in TeleportMath
public static let defaultReminderMessages = [
    "喝点水吧",
    "站起来走走",
    "看看远处放松一下"
]
```

- [ ] **Step 2: Extend LibraryState**

In `Models.swift`, add `import DesktopPetCore` and update `LibraryState`:

```swift
struct LibraryState: Codable {
    var clips: [PetClip]
    var playbackMode: PlaybackMode
    var petScale: Double
    var alwaysOnTop: Bool
    var clickThrough: Bool
    var autoLinkThreshold: Double
    var autoLinkEnabled: Bool
    var activeQueue: [String]
    var teleportEnabled: Bool
    var teleportFrequency: Double
    var cursorNudgeEnabled: Bool
    var reminderMessages: [String]

    static let empty = LibraryState(
        clips: [],
        playbackMode: .sequential,
        petScale: 1.0,
        alwaysOnTop: true,
        clickThrough: false,
        autoLinkThreshold: 0.82,
        autoLinkEnabled: true,
        activeQueue: [],
        teleportEnabled: false,
        teleportFrequency: 0.5,
        cursorNudgeEnabled: false,
        reminderMessages: TeleportMath.defaultReminderMessages
    )

    enum CodingKeys: String, CodingKey {
        case clips, playbackMode, petScale, alwaysOnTop, clickThrough
        case autoLinkThreshold, autoLinkEnabled, activeQueue
        case teleportEnabled, teleportFrequency, cursorNudgeEnabled, reminderMessages
    }

    init(
        clips: [PetClip],
        playbackMode: PlaybackMode,
        petScale: Double,
        alwaysOnTop: Bool,
        clickThrough: Bool,
        autoLinkThreshold: Double,
        autoLinkEnabled: Bool,
        activeQueue: [String],
        teleportEnabled: Bool,
        teleportFrequency: Double,
        cursorNudgeEnabled: Bool,
        reminderMessages: [String]
    ) {
        self.clips = clips
        self.playbackMode = playbackMode
        self.petScale = petScale
        self.alwaysOnTop = alwaysOnTop
        self.clickThrough = clickThrough
        self.autoLinkThreshold = autoLinkThreshold
        self.autoLinkEnabled = autoLinkEnabled
        self.activeQueue = activeQueue
        self.teleportEnabled = teleportEnabled
        self.teleportFrequency = teleportFrequency
        self.cursorNudgeEnabled = cursorNudgeEnabled
        self.reminderMessages = reminderMessages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decode([PetClip].self, forKey: .clips)
        playbackMode = try c.decode(PlaybackMode.self, forKey: .playbackMode)
        petScale = try c.decode(Double.self, forKey: .petScale)
        alwaysOnTop = try c.decode(Bool.self, forKey: .alwaysOnTop)
        clickThrough = try c.decode(Bool.self, forKey: .clickThrough)
        autoLinkThreshold = try c.decode(Double.self, forKey: .autoLinkThreshold)
        autoLinkEnabled = try c.decode(Bool.self, forKey: .autoLinkEnabled)
        activeQueue = try c.decodeIfPresent([String].self, forKey: .activeQueue) ?? []
        teleportEnabled = try c.decodeIfPresent(Bool.self, forKey: .teleportEnabled) ?? false
        teleportFrequency = try c.decodeIfPresent(Double.self, forKey: .teleportFrequency) ?? 0.5
        cursorNudgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .cursorNudgeEnabled) ?? false
        reminderMessages = try c.decodeIfPresent([String].self, forKey: .reminderMessages)
            ?? TeleportMath.defaultReminderMessages
    }
}
```

Update any other `LibraryState(...)` memberwise call sites if the compiler reports missing arguments (only `.empty` and `init(from:)` should construct it today).

- [ ] **Step 3: Build**

Run: `swift build`

Expected: success. Existing `library.json` without new keys still loads via `decodeIfPresent`.

- [ ] **Step 4: Manual decode smoke**

Temporarily log on launch once, or run a one-off in lldb — confirm old library loads with `teleportEnabled == false`. Remove any temporary log before finishing the task.

---

### Task 4: Settings UI

**Files:**
- Modify: `Sources/DesktopPet/LibraryWindowController.swift`

**Interfaces:**
- Consumes: `store.state.teleport*` fields
- Produces: user can toggle/slider/edit; posts `.libraryDidChange`

- [ ] **Step 1: Add controls as properties**

Near existing toggles (`topToggle`, etc.):

```swift
private let teleportToggle = NSButton(checkboxWithTitle: "随机隐现", target: nil, action: nil)
private let teleportFrequencySlider = NSSlider()
private let cursorNudgeToggle = NSButton(checkboxWithTitle: "鼠标附近提醒", target: nil, action: nil)
private let editRemindersButton = NSButton(title: "编辑提醒文案…", target: nil, action: nil)
```

- [ ] **Step 2: Add row 3 in `makeSettings()`**

After `row2`, create horizontal `row3`:

```swift
let freqLabel = NSTextField(labelWithString: "隐现频率")
teleportFrequencySlider.minValue = 0
teleportFrequencySlider.maxValue = 1
teleportFrequencySlider.doubleValue = store.state.teleportFrequency
teleportFrequencySlider.target = self
teleportFrequencySlider.action = #selector(teleportSettingsChanged)
teleportFrequencySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
teleportToggle.target = self
teleportToggle.action = #selector(teleportSettingsChanged)
cursorNudgeToggle.target = self
cursorNudgeToggle.action = #selector(teleportSettingsChanged)
editRemindersButton.target = self
editRemindersButton.action = #selector(editReminderMessages)
editRemindersButton.bezelStyle = .rounded

row3.addArrangedSubview(teleportToggle)
row3.addArrangedSubview(freqLabel)
row3.addArrangedSubview(teleportFrequencySlider)
row3.addArrangedSubview(cursorNudgeToggle)
row3.addArrangedSubview(editRemindersButton)
row3.addArrangedSubview(NSView())
col.addArrangedSubview(row3)
```

Raise wrap height from `110` to `150`.

- [ ] **Step 3: Wire reload + actions**

In `reload`:

```swift
teleportToggle.state = store.state.teleportEnabled ? .on : .off
teleportFrequencySlider.doubleValue = store.state.teleportFrequency
cursorNudgeToggle.state = store.state.cursorNudgeEnabled ? .on : .off
teleportFrequencySlider.isEnabled = store.state.teleportEnabled
cursorNudgeToggle.isEnabled = store.state.teleportEnabled
editRemindersButton.isEnabled = store.state.teleportEnabled
```

```swift
@objc private func teleportSettingsChanged() {
    store.update {
        $0.teleportEnabled = teleportToggle.state == .on
        $0.teleportFrequency = teleportFrequencySlider.doubleValue
        $0.cursorNudgeEnabled = cursorNudgeToggle.state == .on
    }
    teleportFrequencySlider.isEnabled = store.state.teleportEnabled
    cursorNudgeToggle.isEnabled = store.state.teleportEnabled
    editRemindersButton.isEnabled = store.state.teleportEnabled
    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
}

@objc private func editReminderMessages() {
    let panel = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    panel.title = "提醒文案（每行一条）"
    let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 388, height: 180))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: scroll.bounds)
    text.string = store.state.reminderMessages.joined(separator: "\n")
    text.isRichText = false
    text.font = .systemFont(ofSize: 13)
    scroll.documentView = text
    let save = NSButton(title: "保存", target: nil, action: nil)
    save.bezelStyle = .rounded
    save.frame = NSRect(x: 320, y: 16, width: 84, height: 28)
    let cancel = NSButton(title: "取消", target: nil, action: nil)
    cancel.bezelStyle = .rounded
    cancel.frame = NSRect(x: 230, y: 16, width: 84, height: 28)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    host.addSubview(scroll)
    host.addSubview(save)
    host.addSubview(cancel)
    panel.contentView = host

    weak var weakPanel = panel
    cancel.target = self
    // Use a small helper object or endSheet pattern:
    // Prefer: beginSheet on library window.
}
```

Implement sheet properly:

```swift
@objc private func editReminderMessages() {
    guard let parent = window else { return }
    let alert = NSAlert()
    alert.messageText = "提醒文案"
    alert.informativeText = "每行一条，保存后随机抽取。"
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let textView = NSTextView(frame: scroll.bounds)
    textView.autoresizingMask = [.width, .height]
    textView.string = store.state.reminderMessages.joined(separator: "\n")
    textView.isRichText = false
    textView.font = .systemFont(ofSize: 13)
    scroll.documentView = textView
    alert.accessoryView = scroll
    alert.beginSheetModal(for: parent) { [weak self] response in
        guard let self, response == .alertFirstButtonReturn else { return }
        let lines = textView.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.store.update { $0.reminderMessages = lines }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
```

- [ ] **Step 4: Build + manual UI check**

Run: `swift build`  
Launch app, open library: see new controls; toggle enables slider; edit sheet saves lines into `library.json`.

---

### Task 5: Pet window host API + drag cancel

**Files:**
- Modify: `Sources/DesktopPet/PetWindowController.swift`

**Interfaces:**
- Produces:
  - `PetContentView.onDragBegan: (() -> Void)?`
  - `PetWindowController.effectHostView: NSView` (contentView)
  - `func setPetHiddenForTeleport(_ hidden: Bool)`
  - `func movePetForTeleport(to origin: CGPoint)` — sets origin + persists UserDefaults
  - `func currentPetFrame() -> CGRect`
  - `var onTeleportDragCancel: (() -> Void)?` on controller, forwarded from content view

- [ ] **Step 1: Extend PetContentView**

```swift
var onDragBegan: (() -> Void)?

override func mouseDown(with event: NSEvent) {
    onDragBegan?()
    guard let window else { return }
    let loc = event.locationInWindow
    dragOffset = NSPoint(x: loc.x, y: loc.y)
    window.makeKeyAndOrderFront(nil)
}
```

- [ ] **Step 2: Add controller APIs**

```swift
var onTeleportDragCancel: (() -> Void)?

var effectHost: PetContentView { contentView }

func currentPetFrame() -> CGRect {
    window?.frame ?? .zero
}

func setPetHiddenForTeleport(_ hidden: Bool) {
    contentView.isHidden = hidden
    // Keep window ordered front; hit testing naturally fails when content hidden.
}

func movePetForTeleport(to origin: CGPoint) {
    guard let window else { return }
    window.setFrameOrigin(origin)
    UserDefaults.standard.set(origin.x, forKey: "petOriginX")
    UserDefaults.standard.set(origin.y, forKey: "petOriginY")
}

func restorePetPresentation() {
    contentView.isHidden = false
    contentView.alphaValue = 1
    contentView.layer?.opacity = 1
    contentView.layer?.transform = CATransform3DIdentity
}
```

In `init`, after creating contentView:

```swift
contentView.onDragBegan = { [weak self] in
    self?.onTeleportDragCancel?()
}
```

- [ ] **Step 3: Build**

Run: `swift build`  
Expected: success

---

### Task 6: TeleportEffectRenderer (three styles + bubble)

**Files:**
- Create: `Sources/DesktopPet/TeleportEffectRenderer.swift`

**Interfaces:**
- Consumes: `TeleportEffectStyle` from DesktopPetCore; host `NSView`
- Produces:
  - `final class TeleportEffectRenderer`
  - `func playVanish(style: TeleportEffectStyle, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void)`
  - `func playAppear(style: TeleportEffectStyle, onPet: NSView, duration: CFTimeInterval, completion: @escaping () -> Void)`
  - `func cancel()`
  - `func showReminderBubble(text: String, near petView: NSView, duration: TimeInterval)`
  - `func dismissBubble()`

- [ ] **Step 1: Scaffold renderer with cancel + overlay**

```swift
import AppKit
import DesktopPetCore

@MainActor
final class TeleportEffectRenderer {
    private weak var host: NSView?
    private let overlay = CALayer()
    private var completionWorkItem: DispatchWorkItem?
    private var bubbleView: NSTextField?

    init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        overlay.name = "teleportOverlay"
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(overlay)
    }

    func cancel() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        overlay.removeAllAnimations()
        if let host {
            host.layer?.removeAllAnimations()
            host.alphaValue = 1
            host.layer?.opacity = 1
            host.layer?.transform = CATransform3DIdentity
        }
        dismissBubble()
    }

    private func finishAfter(_ duration: CFTimeInterval, completion: @escaping () -> Void) {
        let work = DispatchWorkItem { completion() }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // playVanish / playAppear / styles / bubble implemented in following steps
}
```

- [ ] **Step 2: Implement portal vanish/appear**

Durations: portal `0.65`, particles `0.75`, warp `0.55`.

Portal vanish sketch:

```swift
func playVanish(style: TeleportEffectStyle, onPet: NSView, completion: @escaping () -> Void) {
    cancel() // clear prior, but do not call completion
    // Re-add overlay if cancel cleared it — ensure overlay still attached
    ensureOverlay(on: onPet)
    switch style {
    case .portal: animatePortal(vanish: true, onPet: onPet, completion: completion)
    case .particles: animateParticles(vanish: true, onPet: onPet, completion: completion)
    case .warp: animateWarp(vanish: true, onPet: onPet, completion: completion)
    }
}
```

`animatePortal`:

- Add `CAShapeLayer` ellipse centered lower-mid of bounds; stroke cyan `NSColor(calibratedRed:0.35, green:0.85, blue:1, alpha:1)`, `shadowColor` violet
- Animate `transform.scale` 0.2→1.2 then stroke end collapse; animate pet `opacity` 1→0 and slight scale toward ring
- `finishAfter(0.65, completion)`

Appear: reverse opacity 0→1, ring open then close.

- [ ] **Step 3: Implement particles**

- Create `CAEmitterLayer` at pet center; `CAEmitterCell` with small square contents (1x1 cyan image), `birthRate` high briefly, `velocity` outward for vanish / negative for appear
- Fade pet opacity in parallel
- On completion remove emitter

- [ ] **Step 4: Implement warp**

- Expanding stroked circles (2–3 `CAShapeLayer`) with increasing path radius + fading opacity
- Pet: brief `CATransform3D` scale (1, 1.15, 1) then opacity → 0
- Appear: from scale 0.7 + opacity 0 → identity

- [ ] **Step 5: Reminder bubble**

```swift
func showReminderBubble(text: String, near petView: NSView, duration: TimeInterval = 3.5) {
    dismissBubble()
    guard let petView = host ?? petView as NSView? else { return }
    let label = NSTextField(labelWithString: text)
    label.wantsLayer = true
    label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
    label.layer?.cornerRadius = 8
    label.textColor = .white
    label.font = .systemFont(ofSize: 12)
    label.alignment = .center
    label.drawsBackground = false
    label.sizeToFit()
    var frame = label.frame
    frame.size.width += 16
    frame.size.height += 10
    frame.origin.x = (petView.bounds.width - frame.width) / 2
    frame.origin.y = petView.bounds.height + 6
    // If bubble would go off screen top, place below:
    if let win = petView.window {
        let midY = win.frame.midY
        if let screen = win.screen, midY > screen.visibleFrame.midY {
            frame.origin.y = -frame.height - 6
        }
    }
    label.frame = frame
    label.alphaValue = 0
    petView.addSubview(label)
    bubbleView = label
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.2
        label.animator().alphaValue = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
        self?.dismissBubble()
    }
}

func dismissBubble() {
    bubbleView?.removeFromSuperview()
    bubbleView = nil
}
```

Override bubble hit testing by subclassing or:

```swift
final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
```

- [ ] **Step 6: Build**

Run: `swift build`

Expected: success

---

### Task 7: TeleportController state machine

**Files:**
- Create: `Sources/DesktopPet/TeleportController.swift`

**Interfaces:**
- Consumes: `LibraryStore`, `PetWindowController`, `TeleportEffectRenderer`, `TeleportMath`
- Produces:
  - `final class TeleportController`
  - `func start()`, `func stop()`, `func syncFromStore()`, `func setPetVisible(_ visible: Bool)` (menu hide/show)
  - Internal phases matching spec

- [ ] **Step 1: Implement controller skeleton**

```swift
import AppKit
import DesktopPetCore

@MainActor
final class TeleportController {
    private enum Phase {
        case idle
        case vanishing
        case hidden
        case appearing
    }

    private let store: LibraryStore
    private let pet: PetWindowController
    private let effects: TeleportEffectRenderer

    private var phase: Phase = .idle
    private var dwellTimer: Timer?
    private var hiddenWork: DispatchWorkItem?
    private var petOrderedVisible = true
    private var originMovedThisTrip = false
    private var pendingMode: TeleportLandingMode = .corner
    private var pendingStyle: TeleportEffectStyle = .portal

    init(store: LibraryStore, pet: PetWindowController) {
        self.store = store
        self.pet = pet
        self.effects = TeleportEffectRenderer(host: pet.effectHost)
        pet.onTeleportDragCancel = { [weak self] in
            self?.cancelInFlight(reschedule: true)
        }
    }

    func start() {
        syncFromStore()
    }

    func stop() {
        cancelInFlight(reschedule: false)
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    func setPetVisible(_ visible: Bool) {
        petOrderedVisible = visible
        if !visible {
            cancelInFlight(reschedule: false)
            dwellTimer?.invalidate()
            dwellTimer = nil
        } else {
            syncFromStore()
        }
    }

    func syncFromStore() {
        guard store.state.teleportEnabled, petOrderedVisible else {
            cancelInFlight(reschedule: false)
            dwellTimer?.invalidate()
            dwellTimer = nil
            pet.restorePetPresentation()
            return
        }
        if phase == .idle {
            scheduleDwell()
        }
    }
}
```

- [ ] **Step 2: Scheduling + trip start**

```swift
    private func scheduleDwell() {
        dwellTimer?.invalidate()
        guard store.state.teleportEnabled, petOrderedVisible, phase == .idle else { return }
        let wait = TeleportMath.scheduleDwell(
            frequency: store.state.teleportFrequency,
            unitRandom: Double.random(in: 0...1)
        )
        dwellTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginTrip() }
        }
        RunLoop.main.add(dwellTimer!, forMode: .common)
    }

    private func beginTrip() {
        guard store.state.teleportEnabled, petOrderedVisible, phase == .idle else { return }
        pendingStyle = TeleportMath.pickStyle(unitRandom: Double.random(in: 0...1))
        pendingMode = TeleportMath.pickLandingMode(
            nudgeEnabled: store.state.cursorNudgeEnabled,
            unitRandom: Double.random(in: 0...1)
        )
        originMovedThisTrip = false
        phase = .vanishing
        effects.playVanish(style: pendingStyle, onPet: pet.effectHost) { [weak self] in
            self?.enterHidden()
        }
    }
```

- [ ] **Step 3: Hidden → move → appear → bubble**

```swift
    private func enterHidden() {
        guard phase == .vanishing else { return }
        phase = .hidden
        pet.setPetHiddenForTeleport(true)

        let destination = resolveDestination()
        // Move only after vanish (spec)
        pet.movePetForTeleport(to: destination)
        originMovedThisTrip = true

        let pause = TeleportMath.hiddenDuration(frequency: store.state.teleportFrequency)
        let work = DispatchWorkItem { [weak self] in self?.beginAppear() }
        hiddenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
    }

    private func resolveDestination() -> CGPoint {
        let frame = pet.currentPetFrame()
        let size = frame.size
        let screens = NSScreen.screens.map { TeleportScreenBox(visibleFrame: $0.visibleFrame) }
        guard !screens.isEmpty else { return frame.origin }

        if pendingMode == .cursorNudge {
            let cursor = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
            if let screen,
               let nudge = TeleportMath.cursorNudgeOrigin(
                cursor: cursor,
                petSize: size,
                visibleFrame: screen.visibleFrame,
                angleUnit: Double.random(in: 0...1),
                radiusUnit: Double.random(in: 0...1)
               ) {
                return nudge
            }
            pendingMode = .corner // fallback: no bubble
        }

        var randoms: [Double] = []
        for _ in 0..<48 { randoms.append(Double.random(in: 0...1)) }
        return TeleportMath.pickCornerOrigin(
            screens: screens,
            petSize: size,
            currentOrigin: frame.origin,
            unitRandoms: randoms
        )
    }

    private func beginAppear() {
        guard phase == .hidden else { return }
        phase = .appearing
        pet.setPetHiddenForTeleport(false)
        pet.effectHost.alphaValue = 0
        effects.playAppear(style: pendingStyle, onPet: pet.effectHost) { [weak self] in
            self?.finishTrip()
        }
    }

    private func finishTrip() {
        guard phase == .appearing else { return }
        if pendingMode == .cursorNudge {
            let messages = store.state.reminderMessages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let text = messages.randomElement() {
                effects.showReminderBubble(text: text, near: pet.effectHost)
            }
        }
        phase = .idle
        scheduleDwell()
    }
```

- [ ] **Step 4: Cancel semantics**

```swift
    private func cancelInFlight(reschedule: Bool) {
        hiddenWork?.cancel()
        hiddenWork = nil
        effects.cancel()
        pet.restorePetPresentation()
        // Origin: if not moved, stays; if moved, keep new (already applied)
        phase = .idle
        originMovedThisTrip = false
        if reschedule {
            scheduleDwell()
        }
    }
```

- [ ] **Step 5: Build**

Run: `swift build`

Expected: success

---

### Task 8: AppDelegate wiring

**Files:**
- Modify: `Sources/DesktopPet/AppDelegate.swift`

**Interfaces:**
- Consumes: `TeleportController`
- Produces: teleport runs with app; menu hide pauses; library changes sync settings

- [ ] **Step 1: Add property and start**

```swift
private var teleportController: TeleportController?
```

In `applicationDidFinishLaunching`, after `petWindow` is shown:

```swift
let teleport = TeleportController(store: store, pet: pet)
teleportController = teleport
teleport.start()
```

In `handleLibraryChange`:

```swift
teleportController?.syncFromStore()
```

- [ ] **Step 2: Pause on menu toggle**

```swift
@objc func togglePet() {
    guard let window = petWindow?.window else { return }
    if window.isVisible {
        window.orderOut(nil)
        teleportController?.setPetVisible(false)
    } else {
        window.orderFront(nil)
        teleportController?.setPetVisible(true)
    }
}
```

- [ ] **Step 3: Build + run**

Run: `swift build -c release` (or debug) and launch.

Manual checklist from spec:

1. Master off → no teleport  
2. Master on, frequency extremes → slow vs fast  
3. Multi-monitor corners  
4. Cursor nudge + custom bubble  
5. Drag mid-vanish / hidden / appear cancels correctly  
6. Click-through: teleport continues  
7. Menu hide/show pauses/resumes  
8. Relaunch persists settings + position  

- [ ] **Step 4: Fix timing for QA**

Optional temporary debug: while testing, force `dwellInterval` shorter via a `#if DEBUG` override of schedule to 5s — remove before finishing if added.

---

## Spec coverage checklist

| Spec item | Task |
|-----------|------|
| LibraryState fields + defaults | 3 |
| Settings UI + message editor | 4 |
| Frequency lerp + jitter | 1 |
| Corner multi-screen landing | 2, 7 |
| Cursor nudge 1/4 + fallback | 2, 7 |
| State machine + cancel on drag | 5, 7 |
| Origin move only after vanish | 7 |
| portal / particles / warp | 6 |
| Reminder bubble | 6, 7 |
| Menu hide pause | 8 |
| Persist position | 5, 7 |
| Unit tests for math | 1, 2 |

## Self-review notes

- No TBD placeholders left in tasks
- `playVanish`/`playAppear` signatures unified (duration derived per style inside renderer)
- `PetWindowController.effectHost` naming used consistently in Tasks 5–7
- Commit steps omitted per user git rule; agents must not commit unless asked
