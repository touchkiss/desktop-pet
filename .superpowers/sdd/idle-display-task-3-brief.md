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

