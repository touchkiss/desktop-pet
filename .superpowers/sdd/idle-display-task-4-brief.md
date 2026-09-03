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

