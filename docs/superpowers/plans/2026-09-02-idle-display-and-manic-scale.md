# Idle Display Protection and Manic Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent macOS idle-display-sleep checkbox and an idle-triggered, user-configurable cat enlargement phase that immediately resets on real input without blocking manual lock.

**Architecture:** Put delay, scale, phase, and lease state rules in `DesktopPetCore`; wrap IOKit in one `DesktopPet` adapter; persist settings in `LibraryState`; let `AppDelegate` sample HID idle time once per second and synchronize both runtime features. `PetWindowController` owns the current presentation multiplier and final window geometry so normal playback and teleport landing use one size source.

**Tech Stack:** Swift 5.9, Swift Package Manager, AppKit, CoreGraphics, IOKit power-management assertions, XCTest; macOS 13+.

## Global Constraints

- Use `PreventUserIdleDisplaySleep`; do not run `caffeinate`, synthesize input, or modify macOS/MDM security settings.
- Manual `Control-Command-Q`, Apple-menu lock, lid close, low-battery sleep, and explicit sleep must remain untouched.
- Normal scale remains `0.4×–2.2×`; manic scale is `1.0×–3.0×`, default `2.0×`.
- Idle-delay choices are exactly `关闭 / 1 / 3 / 5 / 10 / 15 / 30 分钟`; a missing legacy value defaults to 5 minutes.
- Cursor-prey target point size never receives the manic multiplier; cat clips, including cursor-interaction cat clips, do.
- Preserve all pre-existing uncommitted work. For modified tracked files, stage only this feature's hunks with `git add -p`, inspect `git diff --cached`, and never stage unrelated hunks.

## File Map

- Create `Sources/DesktopPetCore/IdlePresentationPolicy.swift`: supported delays, safe scale/delay resolution, phase decision, and effective presentation multiplier.
- Create `Sources/DesktopPetCore/IdleDisplaySleepLease.swift`: testable acquire/release lifecycle with idempotency and failure semantics.
- Create `Tests/DesktopPetTests/IdlePresentationPolicyTests.swift`: deterministic policy and legacy-default tests.
- Create `Tests/DesktopPetTests/IdleDisplaySleepLeaseTests.swift`: fake-backend lifecycle tests.
- Create `Sources/DesktopPet/IOKitIdleDisplaySleepController.swift`: actual IOKit assertion adapter.
- Modify `Package.swift`: link IOKit to the executable target.
- Modify `Sources/DesktopPet/Models.swift`: persist and compatibly decode the three new settings; apply an explicit presentation multiplier to cat sizes.
- Modify `Sources/DesktopPet/LibraryWindowController.swift`: checkbox, delay popup, manic-scale slider/value label, persistence actions, and error presentation hook.
- Modify `Sources/DesktopPet/PetWindowController.swift`: stage multiplier, bottom-center resize, screen clamping, and shared effective-size method.
- Modify `Sources/DesktopPet/TeleportController.swift`: ask `PetWindowController` for landing size.
- Modify `Sources/DesktopPet/AppDelegate.swift`: synchronize the IOKit lease, sample HID idle time, change stages, report assertion failures, and release on termination.
- Modify `README.md`: document the new controls and precise manual-lock/security boundary.

---

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

### Task 2: Testable display-sleep lease

**Files:**
- Create: `Sources/DesktopPetCore/IdleDisplaySleepLease.swift`
- Test: `Tests/DesktopPetTests/IdleDisplaySleepLeaseTests.swift`

**Interfaces:**
- Consumes: injected `acquire: () throws -> UInt32` and `release: (UInt32) throws -> Void` closures.
- Produces: `IdleDisplaySleepLease.isEnabled` and `setEnabled(_:) throws`.

- [ ] **Step 1: Write failing lease lifecycle tests**

```swift
import XCTest
@testable import DesktopPetCore

final class IdleDisplaySleepLeaseTests: XCTestCase {
    private enum TestError: Error { case failed }

    func testEnableAndDisableAreIdempotent() throws {
        var acquireCount = 0
        var released: [UInt32] = []
        let lease = IdleDisplaySleepLease(
            acquire: { acquireCount += 1; return 42 },
            release: { released.append($0) }
        )

        try lease.setEnabled(true)
        try lease.setEnabled(true)
        XCTAssertTrue(lease.isEnabled)
        XCTAssertEqual(acquireCount, 1)

        try lease.setEnabled(false)
        try lease.setEnabled(false)
        XCTAssertFalse(lease.isEnabled)
        XCTAssertEqual(released, [42])
    }

    func testFailedAcquireDoesNotClaimEnabled() {
        let lease = IdleDisplaySleepLease(
            acquire: { throw TestError.failed },
            release: { _ in }
        )
        XCTAssertThrowsError(try lease.setEnabled(true))
        XCTAssertFalse(lease.isEnabled)
    }

    func testFailedReleaseClearsLocalLeaseState() throws {
        let lease = IdleDisplaySleepLease(
            acquire: { 7 },
            release: { _ in throw TestError.failed }
        )
        try lease.setEnabled(true)
        XCTAssertThrowsError(try lease.setEnabled(false))
        XCTAssertFalse(lease.isEnabled)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter IdleDisplaySleepLeaseTests`

Expected: compilation fails because `IdleDisplaySleepLease` does not exist.

- [ ] **Step 3: Implement the minimal lease state machine**

```swift
public final class IdleDisplaySleepLease {
    public typealias Acquire = () throws -> UInt32
    public typealias Release = (UInt32) throws -> Void

    private let acquire: Acquire
    private let release: Release
    private var assertionID: UInt32?

    public var isEnabled: Bool { assertionID != nil }

    public init(acquire: @escaping Acquire, release: @escaping Release) {
        self.acquire = acquire
        self.release = release
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard assertionID == nil else { return }
            assertionID = try acquire()
        } else {
            guard let id = assertionID else { return }
            assertionID = nil
            try release(id)
        }
    }

    deinit {
        guard let id = assertionID else { return }
        try? release(id)
    }
}
```

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter IdleDisplaySleepLeaseTests`

Expected: 3 tests pass.

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 5: Commit only the new lease files**

```bash
git add Sources/DesktopPetCore/IdleDisplaySleepLease.swift Tests/DesktopPetTests/IdleDisplaySleepLeaseTests.swift
git diff --cached --check
git commit -m "[电源] 新增显示休眠断言租约状态机"
```

### Task 3: Persist settings and expose controls

**Files:**
- Modify: `Sources/DesktopPet/Models.swift` (`LibraryState` fields, defaults, coding keys, initializer, decoder; `PetClip.effectiveDisplaySize`)
- Modify: `Sources/DesktopPet/LibraryWindowController.swift` (global controls, settings row, reload, action methods, error hook)

**Interfaces:**
- Consumes: `IdlePresentationPolicy` constants and resolvers from Task 1.
- Produces: `LibraryState.preventIdleDisplaySleep: Bool`, `manicIdleDelay: TimeInterval?`, `manicScale: Double`, `LibraryWindowController.presentIdleDisplaySleepError(_:)`, and `PetClip.effectiveDisplaySize(globalScale:presentationMultiplier:)`.

- [ ] **Step 1: Add a RED compatibility assertion to the policy tests**

Add to `IdlePresentationPolicyTests`:

```swift
func testPersistedManicScaleUsesSafeDefaultAndBounds() {
    XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(nil), 2)
    XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(.nan), 2)
    XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(0.5), 1)
    XCTAssertEqual(IdlePresentationPolicy.resolvedManicScale(4), 3)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter IdlePresentationPolicyTests/testPersistedManicScaleUsesSafeDefaultAndBounds`

Expected: compilation fails because `resolvedManicScale` does not exist.

- [ ] **Step 3: Add the minimal resolver**

Add to `IdlePresentationPolicy`:

```swift
public static func resolvedManicScale(_ storedValue: Double?) -> Double {
    clampedManicScale(storedValue ?? defaultManicScale)
}
```

- [ ] **Step 4: Add compatible persisted state**

Add stored properties to `LibraryState`:

```swift
var preventIdleDisplaySleep: Bool
var manicIdleDelay: TimeInterval?
var manicScale: Double
```

Set `.empty` values to `false`, `IdlePresentationPolicy.defaultIdleDelay`, and `IdlePresentationPolicy.defaultManicScale`. Add all three coding keys and initializer parameters. Decode with presence-aware semantics:

```swift
preventIdleDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .preventIdleDisplaySleep) ?? false
manicIdleDelay = IdlePresentationPolicy.resolvedIdleDelay(
    storedValue: try c.decodeIfPresent(TimeInterval.self, forKey: .manicIdleDelay),
    keyWasPresent: c.contains(.manicIdleDelay)
)
manicScale = IdlePresentationPolicy.resolvedManicScale(
    try c.decodeIfPresent(Double.self, forKey: .manicScale)
)
```

Change the cat size API without multiplying cursor-prey target sizes:

```swift
func effectiveDisplaySize(
    globalScale: Double,
    presentationMultiplier: Double = 1
) -> CGSize {
    let normal = PetClipPresentationPolicy.displaySize(
        width: displayWidth,
        height: displayHeight,
        clipScale: clipScale,
        globalScale: globalScale
    )
    let multiplier = presentationMultiplier.isFinite ? max(1, presentationMultiplier) : 1
    return CGSize(width: normal.width * multiplier, height: normal.height * multiplier)
}
```

- [ ] **Step 5: Add the controls and persistence actions**

Add controller properties:

```swift
private let preventIdleDisplaySleepToggle = NSButton(
    checkboxWithTitle: "阻止自动锁屏与关闭屏幕",
    target: nil,
    action: nil
)
private let manicIdleDelayPopup = NSPopUpButton()
private let manicScaleSlider = NSSlider()
private let manicScaleValueLabel = NSTextField(labelWithString: "2.0×")
```

Build a fourth settings row. Populate the popup with represented seconds (`NSNull()` for “关闭”), configure the slider to `1...3`, and connect all three controls to:

```swift
@objc private func idlePresentationSettingsChanged() {
    let delay = (manicIdleDelayPopup.selectedItem?.representedObject as? NSNumber)?.doubleValue
    store.update {
        $0.preventIdleDisplaySleep = preventIdleDisplaySleepToggle.state == .on
        $0.manicIdleDelay = delay
        $0.manicScale = IdlePresentationPolicy.clampedManicScale(manicScaleSlider.doubleValue)
    }
    manicScaleValueLabel.stringValue = String(format: "%.1f×", store.state.manicScale)
    manicScaleSlider.isEnabled = store.state.manicIdleDelay != nil
    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
}
```

In `reload`, select the exact represented delay, restore checkbox/slider values, refresh the value label, and disable only the multiplier slider when delay is closed. Increase the settings container height enough for the fourth row. Add:

```swift
func presentIdleDisplaySleepError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "无法阻止自动关闭屏幕"
    alert.informativeText = message
    if let window, window.isVisible {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}
```

- [ ] **Step 6: Verify policy tests and compilation**

Run: `swift test --filter IdlePresentationPolicyTests`

Expected: 4 tests pass.

Run: `swift build`

Expected: build succeeds with no compiler errors or warnings introduced by these changes.

- [ ] **Step 7: Stage only feature hunks and commit**

```bash
git add Sources/DesktopPetCore/IdlePresentationPolicy.swift Tests/DesktopPetTests/IdlePresentationPolicyTests.swift
git add -p Sources/DesktopPet/Models.swift Sources/DesktopPet/LibraryWindowController.swift
git diff --cached --check
git diff --cached
git commit -m "[设置] 保存空闲展示选项并增加控制项"
```

Do not accept pre-existing cursor-interaction or material-library hunks while running `git add -p`.

### Task 4: Apply manic scaling to window and teleport geometry

**Files:**
- Modify: `Sources/DesktopPet/PetWindowController.swift`
- Modify: `Sources/DesktopPet/TeleportController.swift`

**Interfaces:**
- Consumes: `PetClip.effectiveDisplaySize(globalScale:presentationMultiplier:)` and `IdlePresentationPolicy`.
- Produces: `PetWindowController.setIdlePresentationPhase(_:)` and `effectiveDisplaySize(for:)`.

- [ ] **Step 1: Add RED tests for combined display size**

Extend `PetClipPresentationPolicyTests` with a pure calculation test by first adding the desired `presentationMultiplier` parameter to the core API call:

```swift
func testDisplaySizeAppliesPresentationMultiplierAfterNormalScale() {
    let size = PetClipPresentationPolicy.displaySize(
        width: 100,
        height: 50,
        clipScale: 0.8,
        globalScale: 1.5,
        presentationMultiplier: 2
    )
    XCTAssertEqual(size.width, 240, accuracy: 0.0001)
    XCTAssertEqual(size.height, 120, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter PetClipPresentationPolicyTests/testDisplaySizeAppliesPresentationMultiplierAfterNormalScale`

Expected: compilation fails because `displaySize` has no `presentationMultiplier` argument.

- [ ] **Step 3: Put the final multiplication in the shared core size API**

Change `PetClipPresentationPolicy.displaySize` to accept a defaulted parameter:

```swift
public static func displaySize(
    width: Int,
    height: Int,
    clipScale: Double,
    globalScale: Double,
    presentationMultiplier: Double = 1
) -> CGSize {
    let normalScale = effectiveScale(clipScale: clipScale, globalScale: globalScale)
    let extraScale = presentationMultiplier.isFinite ? max(1, presentationMultiplier) : 1
    return CGSize(
        width: CGFloat(max(0, width)) * normalScale * extraScale,
        height: CGFloat(max(0, height)) * normalScale * extraScale
    )
}
```

Update `PetClip.effectiveDisplaySize` from Task 3 to delegate directly to this API rather than multiplying a returned size itself.

- [ ] **Step 4: Add presentation state and one size source to the pet window**

Add:

```swift
private(set) var idlePresentationPhase: IdlePresentationPhase = .normal

func setIdlePresentationPhase(_ phase: IdlePresentationPhase) {
    guard idlePresentationPhase != phase else { return }
    idlePresentationPhase = phase
    refreshFrame()
}

func effectiveDisplaySize(for clip: PetClip) -> CGSize {
    clip.effectiveDisplaySize(
        globalScale: store.state.petScale,
        presentationMultiplier: IdlePresentationPolicy.presentationMultiplier(
            manicScale: store.state.manicScale,
            phase: idlePresentationPhase
        )
    )
}
```

Use `effectiveDisplaySize(for:)` in `refreshFrame`. Preserve bottom-center, then clamp the complete padded window frame to `(window.screen ?? NSScreen.main)?.visibleFrame` before `setFrame`:

```swift
let bottom = frame.minY
let centerX = frame.midX
frame.size = NSSize(width: w + effectPadding * 2, height: h + effectPadding * 2)
frame.origin = CGPoint(x: centerX - frame.width / 2, y: bottom)
if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
    frame.origin = TeleportMath.clampOrigin(
        frame.origin,
        petSize: frame.size,
        visibleFrame: visibleFrame
    )
}
window.setFrame(frame, display: true)
```

- [ ] **Step 5: Use the same size for teleport landing**

Replace the direct model calculation in `TeleportController.placeLandingFrame()`:

```swift
let size = pet.effectiveDisplaySize(for: clip)
pet.setTeleportLandingFrame(center: travelTo, size: size)
```

- [ ] **Step 6: Run focused tests, full tests, and build**

Run: `swift test --filter PetClipPresentationPolicyTests`

Expected: all `PetClipPresentationPolicyTests` pass.

Run: `swift test`

Expected: all tests pass.

Run: `swift build`

Expected: build succeeds.

- [ ] **Step 7: Stage only feature hunks and commit**

```bash
git add -p Sources/DesktopPetCore/PetClipPresentationPolicy.swift Tests/DesktopPetTests/PetClipPresentationPolicyTests.swift Sources/DesktopPet/Models.swift Sources/DesktopPet/PetWindowController.swift Sources/DesktopPet/TeleportController.swift
git diff --cached --check
git diff --cached
git commit -m "[展示] 空闲时放大猫猫并保持窗口锚点"
```

Reject every staged hunk unrelated to final-size calculation, presentation phase, or teleport landing size.

### Task 5: Connect IOKit and real HID idle time

**Files:**
- Create: `Sources/DesktopPet/IOKitIdleDisplaySleepController.swift`
- Modify: `Package.swift`
- Modify: `Sources/DesktopPet/AppDelegate.swift`

**Interfaces:**
- Consumes: `IdleDisplaySleepLease`, `IdlePresentationPolicy`, persisted state, library error UI, and pet phase setter.
- Produces: live display assertion and one-second idle-phase synchronization.

- [ ] **Step 1: Implement the IOKit adapter using the already-tested lease**

```swift
import Foundation
import IOKit.pwr_mgt
import DesktopPetCore

struct IOKitPowerAssertionError: LocalizedError {
    let operation: String
    let code: IOReturn

    var errorDescription: String? {
        "\(operation)失败（系统错误码 \(code)）"
    }
}

final class IOKitIdleDisplaySleepController {
    private lazy var lease = IdleDisplaySleepLease(
        acquire: {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "DesktopPet 用户已启用显示保护" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                throw IOKitPowerAssertionError(operation: "创建显示保护", code: result)
            }
            return id
        },
        release: { id in
            let result = IOPMAssertionRelease(id)
            guard result == kIOReturnSuccess else {
                throw IOKitPowerAssertionError(operation: "释放显示保护", code: result)
            }
        }
    )

    var isEnabled: Bool { lease.isEnabled }
    func setEnabled(_ enabled: Bool) throws { try lease.setEnabled(enabled) }
}
```

- [ ] **Step 2: Link IOKit**

Add `.linkedFramework("IOKit")` beside the existing `ServiceManagement` and `Carbon` linker settings in `Package.swift`.

- [ ] **Step 3: Add AppDelegate runtime synchronization**

Add properties:

```swift
private let idleDisplaySleepController = IOKitIdleDisplaySleepController()
private var idlePresentationTimer: Timer?
private var currentIdlePresentationPhase: IdlePresentationPhase = .normal
private var isRecoveringDisplaySleepSetting = false
```

At launch, synchronize the saved assertion and start a repeating one-second common-run-loop timer. Keep the sampling method small:

```swift
private func updateIdlePresentation() {
    let rawIdle = CGEventSource.secondsSinceLastEventType(
        .hidSystemState,
        eventType: .null
    )
    let phase = IdlePresentationPolicy.phase(
        idleSeconds: rawIdle,
        delay: store.state.manicIdleDelay
    )
    guard phase != currentIdlePresentationPhase else { return }
    currentIdlePresentationPhase = phase
    petWindow?.setIdlePresentationPhase(phase)
}
```

In `handleLibraryChange`, call both `synchronizeIdleDisplaySleep()` and `updateIdlePresentation()` before refreshing the current frame. Use a recursion guard for assertion failure:

```swift
private func synchronizeIdleDisplaySleep() {
    guard !isRecoveringDisplaySleepSetting else { return }
    do {
        try idleDisplaySleepController.setEnabled(store.state.preventIdleDisplaySleep)
    } catch {
        isRecoveringDisplaySleepSetting = true
        store.update { $0.preventIdleDisplaySleep = false }
        isRecoveringDisplaySleepSetting = false
        libraryWindow?.presentIdleDisplaySleepError(error.localizedDescription)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
```

Add termination cleanup:

```swift
func applicationWillTerminate(_ notification: Notification) {
    idlePresentationTimer?.invalidate()
    idlePresentationTimer = nil
    do {
        try idleDisplaySleepController.setEnabled(false)
    } catch {
        NSLog("DesktopPet: %@", error.localizedDescription)
    }
}
```

Also call `setEnabled(false)` in `quit()` before `NSApp.terminate(nil)` only if needed to guarantee immediate release; the lease makes duplicate disable calls safe.

- [ ] **Step 4: Build and verify symbols link**

Run: `swift build`

Expected: executable links successfully with IOKit and no unresolved `IOPMAssertion*` symbols.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Stage only runtime feature hunks and commit**

```bash
git add Sources/DesktopPet/IOKitIdleDisplaySleepController.swift
git add -p Package.swift Sources/DesktopPet/AppDelegate.swift
git diff --cached --check
git diff --cached
git commit -m "[电源] 接入空闲显示保护与魔性阶段计时"
```

Reject pre-existing AppDelegate hunks that are unrelated to the assertion, idle timer, phase synchronization, or termination cleanup.

### Task 6: Documentation and end-to-end verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: all completed runtime behavior.
- Produces: user-facing documentation and fresh verification evidence.

- [ ] **Step 1: Document controls and security boundary**

Add concise README bullets:

```markdown
- **阻止自动锁屏与关闭屏幕**：使用 macOS 显示空闲休眠断言保持屏幕常亮；不会阻止 `⌃⌘Q`、系统菜单锁屏、合盖或主动睡眠。
- **空闲魔性展示**：可在 1/3/5/10/15/30 分钟无键鼠输入后，将猫猫按 1.0×–3.0× 额外放大；恢复输入时立即回到正常大小。
```

Explain that independent screen-saver or organization/MDM policy is not bypassed.

- [ ] **Step 2: Run fresh automated verification**

Run: `swift test`

Expected: all XCTest cases pass with zero failures.

Run: `swift build`

Expected: debug build succeeds with exit code 0.

Run: `git diff --check`

Expected: no whitespace errors.

- [ ] **Step 3: Package the app for a launch smoke test**

Run: `./build_app.sh`

Expected: release build succeeds and produces `DesktopPet.app` without tracking it.

- [ ] **Step 4: Perform the macOS-only manual checks**

Launch `DesktopPet.app`, then verify all of the following and record actual observations in the final report:

1. Toggle off/on persistence survives relaunch.
2. With a temporarily short macOS display timeout, enabled display protection prevents idle display shutoff; disabling restores system behavior.
3. `Control-Command-Q` still reaches the lock screen while protection is enabled.
4. Representative idle thresholds enter manic phase and real mouse/keyboard input immediately restores normal size.
5. A `3.0×` manic scale near each screen edge stays visible and bottom-center anchoring is stable.
6. Teleport landing, ordinary clip changes, and cursor-interaction cat clips retain the manic size; cursor-prey target point size does not change.

Do not claim any manual item passed unless it was directly observed. In particular, automated tests and a successful build do not prove macOS power-management behavior.

- [ ] **Step 5: Stage only README feature hunks and commit**

```bash
git add -p README.md
git diff --cached --check
git diff --cached
git commit -m "[文档] 说明显示保护与魔性放大设置"
```

- [ ] **Step 6: Review final scope**

Run: `git status --short` and `git log -6 --oneline`.

Expected: feature commits are visible; all pre-existing user changes remain present and uncommitted unless their exact feature hunks were deliberately staged. Compare the implementation line by line against `docs/superpowers/specs/2026-09-02-idle-display-and-manic-scale-design.md` before reporting completion.
