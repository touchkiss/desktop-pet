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

