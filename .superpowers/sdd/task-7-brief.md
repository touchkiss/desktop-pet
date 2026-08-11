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

