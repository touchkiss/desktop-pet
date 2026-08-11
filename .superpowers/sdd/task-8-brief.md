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
